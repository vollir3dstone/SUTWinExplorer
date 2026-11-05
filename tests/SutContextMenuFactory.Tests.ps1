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
'SutContextMenuFactory tests passed.'