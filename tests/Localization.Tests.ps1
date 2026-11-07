param([switch] $SatelliteOnly)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$assemblyPath = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')).Path
$assembly = if ($SatelliteOnly) { [Reflection.Assembly]::LoadFrom($assemblyPath) } else { [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath)) }
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$getText = $assembly.GetType('SUTWinExplorer.LocalizedText', $true).GetMethod('Get', $flags)
$resources = [xml] [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Assets\Strings\Strings.resx'))
$germanResources = [xml] [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Assets\Strings\Strings.de.resx'))
$keys = @($resources.root.data | ForEach-Object { $_.name })
if (@($keys | Select-Object -Unique).Count -ne $keys.Count) { throw 'Duplicate string resource IDs.' }
$germanKeys = @($germanResources.root.data | ForEach-Object { $_.name })
if (@($germanKeys | Select-Object -Unique).Count -ne $germanKeys.Count -or
    @(Compare-Object $keys $germanKeys).Count -ne 0) { throw 'German resource IDs differ from the neutral resource IDs.' }
$germanValues = @{}
foreach ($resource in $germanResources.root.data) { $germanValues[$resource.name] = [string] $resource.value }
$neutralValues = @{}
foreach ($resource in $resources.root.data) {
    $neutralValues[$resource.name] = [string] $resource.value
    $neutralPlaceholders = @([regex]::Matches([string] $resource.value, '\{\d+\}') | ForEach-Object Value | Sort-Object) -join ','
    $germanPlaceholders = @([regex]::Matches($germanValues[$resource.name], '\{\d+\}') | ForEach-Object Value | Sort-Object) -join ','
    if ($neutralPlaceholders -cne $germanPlaceholders) { throw "Format placeholders differ for $($resource.name)." }
}
$originalCulture = [System.Globalization.CultureInfo]::CurrentUICulture
try {
    $cultures = if ($SatelliteOnly) { @('en-US', 'de-DE', 'fr-FR') } else { @('en-US') }
    foreach ($culture in $cultures) {
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
        foreach ($key in $keys) {
            $value = $getText.Invoke($null, [object[]] @([string] $key))
            if ([string]::IsNullOrEmpty($value)) { throw "Missing resource $key for $culture." }
            if ($culture -eq 'de-DE' -and $value -cne $germanValues[$key]) { throw "German resource $key was not loaded for $culture." }
            if ($culture -ne 'de-DE' -and $value -cne $neutralValues[$key]) { throw "Neutral resource $key was not loaded for $culture." }
        }
    }
    if ($SatelliteOnly) {
        $applyLanguage = $assembly.GetType('SUTWinExplorer.LocalizedText', $true).GetMethod('ApplyLanguageSelection', $flags)
        $languageType = $assembly.GetType('SUTWinExplorer.LanguageSelection', $true)
        $originalDefaultCulture = [System.Globalization.CultureInfo]::DefaultThreadCurrentUICulture
        try {
            $systemCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            foreach ($selection in @('English', 'SystemDefault')) {
                $applyLanguage.Invoke($null, [object[]] @([Enum]::Parse($languageType, $selection), $systemCulture)) | Out-Null
                $expectedCulture = if ($selection -eq 'English') { 'en' } else { 'de-DE' }
                $expectedValues = if ($selection -eq 'English') { $neutralValues } else { $germanValues }
                if ([System.Globalization.CultureInfo]::CurrentUICulture.Name -cne $expectedCulture -or
                    [System.Globalization.CultureInfo]::DefaultThreadCurrentUICulture.Name -cne $expectedCulture -or
                    $getText.Invoke($null, [object[]] @('ConfigurationDialog_Title')) -cne $expectedValues['ConfigurationDialog_Title']) {
                    throw "Language selection $selection did not apply the expected UI culture."
                }
            }
        } finally {
            [System.Globalization.CultureInfo]::DefaultThreadCurrentUICulture = $originalDefaultCulture
        }
        [System.Globalization.CultureInfo]::CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
    } else {
        & (Get-Process -Id $PID).Path -NoProfile -STA -File $PSCommandPath -SatelliteOnly
        if ($LASTEXITCODE -ne 0) { throw 'Satellite resource validation failed.' }
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
    $factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
    $getBaseActionLabel = $factory.GetMethod('GetBaseActionLabel', $flags)
    $getContentActionLabel = $factory.GetMethod('GetContentActionLabel', $flags)
    foreach ($id in @('Properties', 'PrepareCopyToExternal', 'PrepareLinkingFromExternal', 'PrepareMoveToExternal',
        'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'AbortTransfer',
        'LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem', 'Rename', 'Relocate', 'Delete')) {
        if ([string]::IsNullOrEmpty($getBaseActionLabel.Invoke($null, [object[]] @($id)))) { throw "Missing base menu action resource for $id." }
    }
    foreach ($id in @('AbortTransfer',
        'AbortClipboardMove', 'AbortClipboardLink', 'ClipboardItemCopy', 'ClipboardItemMove', 'ClipboardItemLink',
        'LinkExecute', 'CopyExecute', 'MoveExecute', 'New', 'OpenInRunningApp')) {
        if ([string]::IsNullOrEmpty($getContentActionLabel.Invoke($null, [object[]] @($id)))) { throw "Missing content menu action resource for $id." }
    }
    [System.Windows.Application].GetField('_resourceAssembly', $flags).SetValue($null, $assembly)
    $application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
    $application.InitializeComponent()
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $interface = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.InterfaceConfiguration', $true))
    $dialog = $assembly.GetType('SUTWinExplorer.ConfigurationDialog', $true).GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')[0].Invoke([object[]] @($interface))
    $languageGroup = @($dialog.Content.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] -and $_.Name -eq 'LanguageSelectionPanel' })
    if ($languageGroup.Count -ne 1 -or $languageGroup[0].Orientation -ne 'Horizontal' -or
        $languageGroup[0].Children.Count -ne 3 -or $languageGroup[0].Children[0].Text -cne $getText.Invoke($null, [object[]] @('ConfigurationDialog_Label_LanguageSelection'))) { throw 'Language row is missing, incorrectly arranged, or not localized.' }
    $radioButtons = @($languageGroup[0].Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })
    if ($radioButtons.Count -ne 2 -or $radioButtons[0].Name -cne 'EnglishLanguageRadioButton' -or
        $radioButtons[1].Name -cne 'SystemLanguageRadioButton' -or -not $radioButtons[0].IsChecked -or $radioButtons[1].IsChecked -or
        $radioButtons[0].Content -cne $getText.Invoke($null, [object[]] @('ConfigurationDialog_Language_English')) -or
        $radioButtons[1].Content -cne $getText.Invoke($null, [object[]] @('ConfigurationDialog_Language_SystemDefault'))) { throw 'Language radio buttons are incorrect.' }
    $radioButtons[1].IsChecked = $true
    $getConfiguration = $dialog.GetType().GetMethod('GetConfiguration', [Reflection.BindingFlags]'Instance,NonPublic')
    $systemConfiguration = $getConfiguration.Invoke($dialog, @())
    if ($radioButtons[0].IsChecked -or $systemConfiguration.LanguageSelection.ToString() -cne 'SystemDefault') { throw 'System language selection failed.' }
    $radioButtons[0].IsChecked = $true
    if ($radioButtons[1].IsChecked -or $getConfiguration.Invoke($dialog, @()).LanguageSelection.ToString() -cne 'English') { throw 'English language selection failed.' }
    $dialog.Close()
    $reopenedDialog = $assembly.GetType('SUTWinExplorer.ConfigurationDialog', $true).GetConstructors([Reflection.BindingFlags]'Instance,NonPublic')[0].Invoke([object[]] @($systemConfiguration))
    $reopenedGroup = @($reopenedDialog.Content.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] -and $_.Name -eq 'LanguageSelectionPanel' })[0]
    $reopenedButtons = @($reopenedGroup.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })
    if ($reopenedButtons[0].IsChecked -or -not $reopenedButtons[1].IsChecked) { throw 'Saved system language was not selected when reopening the dialog.' }
    $reopenedDialog.Close()
    $contentView = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $openLocation = $contentView.GetType().GetMethod('CreateOpenLocationAction', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($contentView, [object[]] @(,[string[]] @('test.lnk')))
    if ($openLocation.Id -cne 'opencontaining' -or $openLocation.Label -cne $getText.Invoke($null, [object[]] @('ContentMenu_Action_OpenContainingDirectory'))) {
        throw 'Open containing directory action does not use its resource.'
    }
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
    $treeEntry = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.TreeEntry', $true), [object[]] @('test', [string] $PSScriptRoot))
    $createDirectoryActions = $pathview.GetType().GetMethod('CreateDirectoryMenuActions', [Reflection.BindingFlags]'Instance,NonPublic')
    foreach ($enabled in @($false, $true)) {
        $pathview.EnableInternalItemTransfers = $enabled
        $actions = $createDirectoryActions.Invoke($pathview, [object[]] @($treeEntry))
        if (@($actions | Where-Object Id -eq 'Properties').Count -ne 1 -or
            @($actions | Where-Object Id -eq 'AbortTransfer').Count -ne [int] $enabled) {
            throw 'Directory base menu actions were not created correctly.'
        }
    }
    $pathview.GetType().GetMethod('Close', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($pathview, @()) | Out-Null
    $application.Shutdown()
} finally {
    [System.Globalization.CultureInfo]::CurrentUICulture = $originalCulture
}
'Localization tests passed.'