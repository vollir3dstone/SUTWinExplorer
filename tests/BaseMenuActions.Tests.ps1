$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
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
$actionIds = @('Rename', 'NameGet', 'PathGet', 'CopyGet', 'CopyAbort', 'CopyPaste', 'MoveGet', 'MoveAbort', 'MovePaste', 'Delete')
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
function Assert-Menu($actions, [string[]] $expected, [string[]] $disabled) {
    if ((@($actions | ForEach-Object { $_.Id }) -join ',') -cne ($actionIds -join ',')) { throw 'Incorrect action IDs.' }
    if (@($actions | Where-Object { $_.Label -cne 'Lokalisierte Aktion' }).Count -ne 0) { throw 'Action labels were not localized.' }
    $menu = [BaseMenuProbe]::CreatePopupMenu()
    try {
        if (-not [BaseMenuProbe]::AppendMenu($menu, 0, [UIntPtr] 1, 'Shell command')) { throw 'Could not create fixture menu.' }
        $null = $insert.Invoke($null, [object[]] @($menu, $actions))
        $actual = @()
        for ($index = 0; $index -lt [BaseMenuProbe]::GetMenuItemCount($menu); $index++) {
            $state = [BaseMenuProbe]::GetMenuState($menu, $index, 0x400)
            if (($state -band 0x800) -ne 0) { $actual += '|'; continue }
            $text = [Text.StringBuilder]::new(256)
            $null = [BaseMenuProbe]::GetMenuString($menu, $index, $text, $text.Capacity, 0x400)
            $command = [BaseMenuProbe]::GetMenuItemID($menu, $index)
            if ($command -eq 1) { $actual += 'Shell command'; continue }
            $actionIndex = [int] $command - 0x8000
            if ($actionIndex -lt 0 -or $actionIndex -ge $actions.Count) { throw "Incorrect command ID: $command." }
            $id = $actions[$actionIndex].Id
            $actual += $id
            if ($text.ToString() -cne $actions[$actionIndex].Label) { throw "Incorrect display label for $id." }
            if ((($state -band 3) -ne 0) -ne ($id -in $disabled)) { throw "Incorrect enabled state for $id." }
        }
        if (($actual -join ',') -cne ($expected -join ',')) { throw "Incorrect menu: $($actual -join ','); expected $($expected -join ',')." }
    } finally { $null = [BaseMenuProbe]::DestroyMenu($menu) }
}
function Assert-ShellMenu($actions, [string[]] $expected, [bool] $background, [IntPtr] $owner) {
    $create = $factory.GetMethod('GetBaseMenuForContext', [Reflection.BindingFlags]'Static,NonPublic')
    $instance = $create.Invoke($null, [object[]] @([string[]] @($directory), $owner, $actions, $background))
    try {
        $menu = $instance.GetType().GetField('_menu', $flags).GetValue($instance)
        for ($index = 0; $index -lt $expected.Count; $index++) {
            $state = [BaseMenuProbe]::GetMenuState($menu, $index, 0x400)
            $text = [Text.StringBuilder]::new(256)
            $null = [BaseMenuProbe]::GetMenuString($menu, $index, $text, $text.Capacity, 0x400)
            $command = [BaseMenuProbe]::GetMenuItemID($menu, $index)
            $actual = if (($state -band 0x800) -ne 0) { '|' } else {
                $actionIndex = [int] $command - 0x8000
                if ($actionIndex -lt 0 -or $actionIndex -ge $actions.Count) { throw "Incorrect Shell menu command ID: $command." }
                if ($text.ToString() -cne $actions[$actionIndex].Label) { throw 'Incorrect Shell menu display label.' }
                $actions[$actionIndex].Id
            }
            if ($actual -cne $expected[$index]) { throw "Incorrect Shell menu item at ${index}: $actual; expected $($expected[$index])." }
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
    foreach ($name in $actionIds) {
        [System.Windows.Automation.AutomationProperties]::SetName($view.FindName($name + 'Button'), 'Lokalisierte Aktion')
    }
    $createContent = $view.GetType().GetMethod('CreateContextMenuActions', $flags)
    $createDirectory = $pathview.GetType().GetMethod('CreateDirectoryMenuActions', $flags)
    $createBackground = $pathview.GetType().GetMethod('CreateBackgroundMenuActions', $flags)
    $entry = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.TreeEntry', $true), [object[]] @([string] 'folder', [string] $directory))
    $copy = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
    $move = $assembly.GetType('SUTWinExplorer.MoveWorkflowState', $true).GetProperty('Shared').GetValue($null)
    foreach ($case in @('Idle', 'Copy', 'Move')) {
        if ($case -eq 'Copy') { $copy.Prepare([string[]] @($directory)) }
        if ($case -eq 'Move') { $move.Prepare([string[]] @($directory)) }
        $transfer = switch ($case) {
            'Idle' { @('CopyGet', 'MoveGet') }
            'Copy' { @('CopyAbort', 'CopyPaste') }
            'Move' { @('MoveAbort', 'MovePaste') }
        }
        $expected = @('Rename', '|', 'NameGet', 'PathGet') + $transfer + @('|', 'Delete', '|', 'Shell command')
        $directoryActions = $createDirectory.Invoke($pathview, [object[]] @($entry))
        Assert-Menu $directoryActions $expected $(if ($case -eq 'Idle') { @() } else { @('Delete') })
        Assert-ShellMenu $directoryActions $expected[0..($expected.Count - 3)] $false $owner
        $backgroundTransfer = if ($case -eq 'Idle') { @() } else { $transfer }
        $backgroundExpected = @('Rename', '|', 'NameGet', 'PathGet') + $backgroundTransfer + @('|', 'Delete', '|', 'Shell command')
        $backgroundActions = $createBackground.Invoke($pathview, @())
        Assert-Menu $backgroundActions $backgroundExpected @('Rename', 'NameGet', 'PathGet', 'Delete')
        Assert-ShellMenu $backgroundActions $backgroundExpected[0..($backgroundExpected.Count - 3)] $true $owner
        foreach ($name in $actionIds) {
            $enabled = switch ($name) {
                'Rename' { $true } 'NameGet' { $true } 'PathGet' { $true } 'Delete' { $case -eq 'Idle' }
                'CopyGet' { $case -eq 'Idle' } 'MoveGet' { $case -eq 'Idle' }
                'CopyAbort' { $case -eq 'Copy' } 'CopyPaste' { $case -eq 'Copy' }
                'MoveAbort' { $case -eq 'Move' } 'MovePaste' { $case -eq 'Move' }
            }
            $view.FindName($name + 'Button').IsEnabled = $enabled
        }
        Assert-Menu ($createContent.Invoke($view, @())) $expected $(if ($case -eq 'Idle') { @() } else { @('Delete') })
        $copy.Abort()
        $move.Abort()
    }
    $originalClipboard = [System.Windows.Clipboard]::GetDataObject()
    try {
        $window.Content = $pathview
        $window.Width = 800
        $window.Height = 500
        $window.UpdateLayout()
        $nameButton = $view.FindName('NameGetButton')
        $pathButton = $view.FindName('PathGetButton')
        $namePosition = $nameButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $pathPosition = $pathButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        if ($namePosition.X + $nameButton.ActualWidth -gt $pathPosition.X -or [Math]::Abs($namePosition.Y - $pathPosition.Y) -gt 1) {
            throw 'Name get was not laid out directly before Path get.'
        }
        $reveal = $view.GetType().GetMethod('RevealInsertedItems', $flags)
        $null = $reveal.Invoke($view, [object[]] @(,[string[]] @($testFile)))
        Wait-SelectedPaths $view ([string[]] @($testFile))
        if (-not $view.FindName('NameGetButton').IsEnabled) { throw 'Name get was disabled for a single file.' }
        $view.FindName('NameGetButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-ClipboardText 'name with spaces.txt' 'Name get copied an incorrect file name:'
        Wait-SelectedPaths $view ([string[]] @($testFile))
        $view.FindName('PathGetButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-ClipboardText $testFile 'Path get copied an incorrect file path:'
        Wait-SelectedPaths $view ([string[]] @($testFile))
        $contentAction = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq 'NameGet' })[0]
        $contentAction.Invoke.Invoke()
        Assert-ClipboardText 'name with spaces.txt' 'Content menu Name get copied an incorrect file name:'
        $null = $reveal.Invoke($view, [object[]] @(,[string[]] @($testFolder)))
        Wait-SelectedPaths $view ([string[]] @($testFolder))
        $view.FindName('NameGetButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-ClipboardText 'test-folder' 'Name get copied an incorrect folder name:'
        $null = $reveal.Invoke($view, [object[]] @(,[string[]] @($testFile, $testFolder)))
        Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
        if (-not $nameButton.IsEnabled -or -not $pathButton.IsEnabled) { throw 'Name get or Path get was disabled for multiple items.' }
        foreach ($actionId in @('NameGet', 'PathGet')) {
            Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
            $selectedPaths = @($view.FindName('FileList').SelectedItems | ForEach-Object { $_.Entry.FullPath })
            $expectedNames = @($selectedPaths | ForEach-Object { [IO.Path]::GetFileName($_) }) -join [Environment]::NewLine
            $expectedPaths = $selectedPaths -join [Environment]::NewLine
            $expectedText = if ($actionId -eq 'NameGet') { $expectedNames } else { $expectedPaths }
            $view.FindName($actionId + 'Button').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-ClipboardText $expectedText "$actionId copied incorrect text for multiple items:"
            if ([System.Windows.Clipboard]::ContainsFileDropList()) { throw "$actionId unexpectedly copied a file-drop list." }
            Wait-SelectedPaths $view ([string[]] @($testFile, $testFolder))
            $selectedPaths = @($view.FindName('FileList').SelectedItems | ForEach-Object { $_.Entry.FullPath })
            $expectedText = if ($actionId -eq 'NameGet') { @($selectedPaths | ForEach-Object { [IO.Path]::GetFileName($_) }) -join [Environment]::NewLine } else { $selectedPaths -join [Environment]::NewLine }
            $action = @($createContent.Invoke($view, @()) | Where-Object { $_.Id -eq $actionId })[0]
            if (-not $action.IsEnabled) { throw "$actionId was disabled in the Base Menu for multiple items." }
            [System.Windows.Clipboard]::SetText('clipboard test sentinel')
            $action.Invoke.Invoke()
            Assert-ClipboardText $expectedText "Base Menu $actionId copied incorrect text for multiple items:"
        }
        $view.FindName('FileList').SelectedItems.Clear()
        if ($nameButton.IsEnabled -or $pathButton.IsEnabled) { throw 'Name get or Path get was enabled without a selection.' }
        $directoryAction = @($createDirectory.Invoke($pathview, [object[]] @($entry)) | Where-Object { $_.Id -eq 'NameGet' })[0]
        $directoryAction.Invoke.Invoke()
        Assert-ClipboardText ([IO.Path]::GetFileName($directory)) 'Directory menu Name get copied an incorrect folder name:'
        $getName = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('GetFileSystemName', [Reflection.BindingFlags]'Static,NonPublic')
        foreach ($case in @(@('C:\', 'C:'), @('C:\folder\', 'folder'), @('\\server\share\', 'share'))) {
            if ($getName.Invoke($null, [object[]] @($case[0])) -cne $case[1]) { throw "Incorrect filesystem name for $($case[0])." }
        }
    } finally {
        if ($null -eq $originalClipboard) { [System.Windows.Clipboard]::Clear() }
        else { [System.Windows.Clipboard]::SetDataObject($originalClipboard, $true) }
    }
} finally {
    if ($null -ne $copy) { $copy.Abort() }
    if ($null -ne $move) { $move.Abort() }
    if ($null -ne $window) { $window.Close() }
    [IO.Directory]::Delete($directory, $true)
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
}
Write-Host 'Base menu action tests passed.'