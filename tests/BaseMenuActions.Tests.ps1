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
$actionIds = @('Rename', 'PathGet', 'CopyGet', 'CopyAbort', 'CopyPaste', 'MoveGet', 'MoveAbort', 'MovePaste', 'Delete')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutBaseMenu-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
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
        $expected = @('Rename', '|', 'PathGet') + $transfer + @('|', 'Delete', '|', 'Shell command')
        $directoryActions = $createDirectory.Invoke($pathview, [object[]] @($entry))
        Assert-Menu $directoryActions $expected $(if ($case -eq 'Idle') { @() } else { @('Delete') })
        Assert-ShellMenu $directoryActions $expected[0..($expected.Count - 3)] $false $owner
        $backgroundTransfer = if ($case -eq 'Idle') { @() } else { $transfer }
        $backgroundExpected = @('Rename', '|', 'PathGet') + $backgroundTransfer + @('|', 'Delete', '|', 'Shell command')
        $backgroundActions = $createBackground.Invoke($pathview, @())
        Assert-Menu $backgroundActions $backgroundExpected @('Rename', 'PathGet', 'Delete')
        Assert-ShellMenu $backgroundActions $backgroundExpected[0..($backgroundExpected.Count - 3)] $true $owner
        foreach ($name in @('Rename', 'PathGet', 'CopyGet', 'CopyAbort', 'CopyPaste', 'MoveGet', 'MoveAbort', 'MovePaste', 'Delete')) {
            $enabled = switch ($name) {
                'Rename' { $true } 'PathGet' { $true } 'Delete' { $case -eq 'Idle' }
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
} finally {
    if ($null -ne $copy) { $copy.Abort() }
    if ($null -ne $move) { $move.Abort() }
    if ($null -ne $window) { $window.Close() }
    [IO.Directory]::Delete($directory, $true)
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
}
Write-Host 'Base menu action tests passed.'