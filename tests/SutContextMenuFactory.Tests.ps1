. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$menuType = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
$whitelistJson = '{"_type":"directoryMenuWhitelist","extensions":[{"_type":"shellExtension","name":"test","verbs":["TestVerb"],"clsids":["{11111111-2222-3333-4444-555555555555}"]}]}'
$whitelistDocument = [System.Text.Json.JsonDocument]::Parse($whitelistJson)
try {
    $parsedWhitelist = $menuType.GetMethod('ParseDirectoryWhitelist', $flags).Invoke($null, @($whitelistDocument))
    $parsedVerbs = $parsedWhitelist.GetType().GetProperty('Verbs').GetValue($parsedWhitelist)
    $parsedHandlers = $parsedWhitelist.GetType().GetProperty('HandlerIds').GetValue($parsedWhitelist)
    $testHandler = [guid] '{11111111-2222-3333-4444-555555555555}'
    $emptyHandlers = [System.Collections.Generic.HashSet[guid]]::new()
    $eligibleHandler = $menuType.GetMethod('IsEligibleDirectoryHandler', $flags)
    Assert-True ($parsedVerbs.Contains('testverb') -and $parsedHandlers.Contains($testHandler) -and
        $eligibleHandler.Invoke($null, [object[]] @($testHandler, $emptyHandlers, $parsedHandlers)) -and
        -not $eligibleHandler.Invoke($null, [object[]] @([guid]::NewGuid(), $emptyHandlers, $parsedHandlers))) 'Directory whitelist parsing or handler eligibility failed.'
} finally { $whitelistDocument.Dispose() }
$ambiguousMenu = [SutShellMenuProbe]::CreateAmbiguousMenu()
try {
    $labels = $menuType.GetMethod('CollectMenuLabels', $flags).Invoke($null, @($ambiguousMenu))
    $wildcardVerbs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directoryOnlyVerbs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $wildcardVerbs.Add('SharedVerb')
    $null = $directoryOnlyVerbs.Add('DirectoryOnlyVerb')
    $wildcardMatch = $menuType.GetMethod('IsWildcardDirectoryMatch', $flags)
    Assert-True ($labels.Count -eq 2 -and $labels.Contains("item`0Shared") -and $labels.Contains("submenu`0Lazy") -and
        $wildcardMatch.Invoke($null, [object[]] @('sharedverb', $null, $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        $wildcardMatch.Invoke($null, [object[]] @($null, "item`0Shared", $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        $wildcardMatch.Invoke($null, [object[]] @($null, "submenu`0Lazy", $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        -not $wildcardMatch.Invoke($null, [object[]] @('DirectoryOnlyVerb', "item`0Shared", $wildcardVerbs, $directoryOnlyVerbs, $labels)) -and
        -not $wildcardMatch.Invoke($null, [object[]] @($null, "item`0Lazy", $wildcardVerbs, $directoryOnlyVerbs, $labels))) 'Ambiguous wildcard menu matching did not preserve the intended criteria.'
} finally { [void] [SutShellMenuProbe]::DestroyMenu($ambiguousMenu) }
$lazyBackgroundMenu = [SutShellMenuProbe]::CreateLazyBackgroundMenu()
try {
    $null = $menuType.GetMethod('RemoveBackgroundViewMenus', $flags).Invoke($null, [object[]] @($lazyBackgroundMenu, $null))
    $remainingLabels = $menuType.GetMethod('CollectMenuLabels', $flags).Invoke($null, @($lazyBackgroundMenu))
    Assert-True ($remainingLabels.Count -eq 1) 'Lazy Sort and Group submenus were not removed or the New submenu was removed.'
} finally { [void] [SutShellMenuProbe]::DestroyMenu($lazyBackgroundMenu) }
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BaseMenuLayoutProbe
{
    [DllImport("user32.dll")] public static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint position, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int position);
}
'@
$actionType = $assembly.GetType('SUTWinExplorer.ShellMenuAction', $true)
$ids = @('Properties', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem', 'Rename', 'Delete')
$sourceActions = [Array]::CreateInstance($actionType, $ids.Count)
$noop = [Action] { }
for ($index = 0; $index -lt $ids.Count; $index++) {
    $sourceActions.SetValue([Activator]::CreateInstance($actionType, [object[]] @([string] $ids[$index], 'old', $true, $noop, $false, $false)), $index)
}
$relocate = [Activator]::CreateInstance($actionType, [object[]] @('Relocate', 'old', $true, $noop, $false, $false))
$states = @('Link', 'Copy', 'Move') | ForEach-Object { $assembly.GetType("SUTWinExplorer.${_}WorkflowState", $true).GetProperty('Shared').GetValue($null) }
try {
    foreach ($state in $states) { $state.Prepare([string[]] @('C:\test')) }
    $disabledActions = $menuType.GetMethod('CreateBaseActions', $flags).Invoke($null, [object[]] @($sourceActions, $relocate, [string[]] @($PSScriptRoot), [IntPtr]::Zero, $false))
    Assert-True (@($disabledActions | Where-Object Id -in @('AbortTransfer', 'LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem')).Count -eq 0 -and
        @($disabledActions | Where-Object Id -in @('PrepareCopyToExternal', 'PrepareLinkingFromExternal', 'PrepareMoveToExternal')).Count -eq 3) 'Disabled internal transfers affected the wrong Base Menu actions.'
    $actions = $menuType.GetMethod('CreateBaseActions', $flags).Invoke($null, [object[]] @($sourceActions, $relocate, [string[]] @($PSScriptRoot), [IntPtr]::Zero, $true))
    $abort = @($actions | Where-Object Id -eq 'AbortTransfer')[0]
    Assert-True ($abort.IsEnabled) 'Abort transfer was not enabled for prepared transfers.'
    $menu = [BaseMenuLayoutProbe]::CreatePopupMenu()
    try {
        [void] [BaseMenuLayoutProbe]::AppendMenu($menu, 0, [UIntPtr] 1, 'Shell command')
        $null = $menuType.GetMethod('InsertActions', $flags).Invoke($null, [object[]] @($menu, $actions))
        $actual = @(for ($index = 0; $index -lt [SutShellMenuProbe]::GetMenuItemCount($menu); $index++) {
            if (([BaseMenuLayoutProbe]::GetMenuState($menu, $index, 0x400) -band 0x800) -ne 0) { '|' }
            else {
                $command = [BaseMenuLayoutProbe]::GetMenuItemID($menu, $index)
                if ($command -eq 1) { 'ShellCommand' }
                elseif ($command -ge 0x8000 -and $command -lt (0x8000 + $actions.Count)) { $actions[$command - 0x8000].Id }
                else { throw "Unexpected menu command ID: $command" }
            }
        })
        $expected = @('Properties', '|', 'PrepareCopyToExternal', 'PrepareLinkingFromExternal', 'PrepareMoveToExternal', '|', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', '|',
            'AbortTransfer', 'LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem', '|', 'ShellCommand', '|', 'Rename', 'Relocate', '|', 'Delete')
        Assert-True (($actual -join ',') -ceq ($expected -join ',')) "Incorrect base menu layout: $($actual -join ',')"
    } finally { [void] [SutShellMenuProbe]::DestroyMenu($menu) }
    $abort.Invoke.Invoke()
    Assert-True (@($states | Where-Object IsPrepared).Count -eq 0) 'Abort transfer did not clear all prepared transfers.'
    $idleActions = $menuType.GetMethod('CreateBaseActions', $flags).Invoke($null, [object[]] @($sourceActions, $relocate, [string[]] @($PSScriptRoot), [IntPtr]::Zero, $true))
    Assert-True (-not @($idleActions | Where-Object Id -eq 'AbortTransfer')[0].IsEnabled) 'Abort transfer was enabled without a prepared transfer.'
} finally { foreach ($state in $states) { $state.Abort() } }
'SutContextMenuFactory tests passed.'