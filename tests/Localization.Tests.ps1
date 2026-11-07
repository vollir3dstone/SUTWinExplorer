$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$getText = $assembly.GetType('SUTWinExplorer.LocalizedText', $true).GetMethod('Get', $flags)
$resources = [xml] [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Strings.resx'))
$keys = @($resources.root.data | ForEach-Object { $_.name })
if (@($keys | Select-Object -Unique).Count -ne $keys.Count) { throw 'Duplicate string resource IDs.' }
$originalCulture = [System.Globalization.CultureInfo]::CurrentUICulture
try {
    foreach ($culture in @('en-US', 'de-DE')) {
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach ($key in $keys) {
            if ([string]::IsNullOrEmpty($getText.Invoke($null, [object[]] @([string] $key)))) { throw "Missing resource $key for $culture." }
        }
    }
    foreach ($xaml in @('MainWindow.xaml', 'ExplorerTabView.xaml', 'ContentView.xaml', 'UseCasesView.xaml')) {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\$xaml"))
        foreach ($match in [regex]::Matches($text, '\{local:Localized ([A-Za-z0-9_]+)\}')) {
            if ($match.Groups[1].Value -notin $keys) { throw "Missing XAML resource $($match.Groups[1].Value) in $xaml." }
        }
    }
    foreach ($source in Get-ChildItem (Join-Path $PSScriptRoot '..\*.cs')) {
        foreach ($match in [regex]::Matches([IO.File]::ReadAllText($source.FullName), 'LocalizedText\.Get\("([A-Za-z0-9_]+)"\)')) {
            if ($match.Groups[1].Value -notin $keys) { throw "Missing code resource $($match.Groups[1].Value) in $($source.Name)." }
        }
    }
    $getActionLabel = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true).GetMethod('GetActionLabel', $flags)
    foreach ($id in @('Properties', 'PrepareCopyToExternal', 'PrepareLinkingFromExternal', 'PrepareMoveToExternal',
        'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'ItemClipboardPaste', 'AbortTransfer',
        'LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem', 'LinkAbort', 'CopyAbort', 'MoveAbort', 'Rename', 'Relocate', 'Delete',
        'AbortClipboardMove', 'AbortClipboardLink', 'ClipboardItemCopy', 'ClipboardItemMove', 'ClipboardItemLink',
        'LinkExecute', 'CopyExecute', 'MoveExecute', 'New', 'opencontaining', 'OpenInRunningApp')) {
        if ([string]::IsNullOrEmpty($getActionLabel.Invoke($null, [object[]] @($id)))) { throw "Missing action resource for $id." }
    }
    [System.Windows.Application].GetField('_resourceAssembly', $flags).SetValue($null, $assembly)
    $application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
    $application.InitializeComponent()
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $null = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $null = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.UseCasesView', $true))
    $iconType = $assembly.GetType('SUTWinExplorer.ShellMenuIcons', $true)
    $createBitmap = $iconType.GetMethod('CreateBitmap', $flags)
    $releaseBitmap = $iconType.GetMethod('Release', $flags)
    $actionType = $assembly.GetType('SUTWinExplorer.ShellMenuAction', $true)
    foreach ($id in @('LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem', 'LinkExecute', 'CopyExecute', 'MoveExecute', 'Delete')) {
        $action = [Activator]::CreateInstance($actionType, [object[]] @($id, '', $true, [Action] {}, $false, $false))
        $button = [System.Windows.Controls.Button]::new()
        $button.Content = 'x'
        $actionType.GetProperty('IconSource').SetValue($action, $button)
        $bitmap = $createBitmap.Invoke($null, [object[]] @($action, $null))
        if ($bitmap -eq [IntPtr]::Zero) { throw "Missing action icon for $id with short button text." }
        $releaseBitmap.Invoke($null, [object[]] @($bitmap)) | Out-Null
    }
    $pathview = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true), [object[]] @([string] $PSScriptRoot, $false, $null, $null, $null, $null))
    $pathview.GetType().GetMethod('Close', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($pathview, @()) | Out-Null
    $application.Shutdown()
} finally {
    [System.Globalization.CultureInfo]::CurrentUICulture = $originalCulture
}
'Localization tests passed.'