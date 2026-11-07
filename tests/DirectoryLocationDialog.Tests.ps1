. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-location-dialog-' + [guid]::NewGuid().ToString('N'))
$destination = Join-Path $root 'destination'
try {
    $dialogType = $assembly.GetType('SUTWinExplorer.DirectoryLocationDialog', $true)
    $dialog = $dialogType.GetConstructors($flags)[0].Invoke([object[]] @($true, [string] $root, $null, [string] 'operation-parent', $false))
    try {
        $choices = $dialog.Content.Children[0].Children
        Assert-True ($dialog.Title -ceq 'Relocate directory' -and $choices[0].Content -ceq 'Destination (parent)' -and $choices[0].IsChecked -eq $true -and $choices[1].Content -ceq 'Destination and new name' -and $choices[1].IsChecked -ne $true -and $dialog.Content.Children[2].Children[1].Content -ceq 'Relocate') 'The relocation dialog has incorrect labels or default mode.'
        Assert-True ([System.Windows.Automation.AutomationProperties]::GetName($dialog.Content.Children[1]) -ceq 'Destination (parent)') 'The default destination editor has an incorrect accessible name.'
        $choices[1].IsChecked = $true
        Assert-True ($dialogType.GetProperty('DestinationIncludesName', $flags).GetValue($dialog) -and $choices[0].IsChecked -ne $true) 'The relocation modes are not mutually exclusive.'
        Assert-True ([System.Windows.Automation.AutomationProperties]::GetName($dialog.Content.Children[1]) -ceq 'Destination and new name') 'The named destination editor has an incorrect accessible name.'
        Assert-True ($dialog.Content.Children[1].Text -ceq (Join-Path $root 'operation-parent')) 'Switching to the named destination did not append the current directory name.'
        $dialog.Content.Children[1].Text = Join-Path $destination 'different-name'
        $choices[0].IsChecked = $true
        Assert-True ($dialog.Content.Children[1].Text -ceq $destination) 'Switching to the parent destination did not remove the entered name.'
        $choices[1].IsChecked = $true
        Assert-True ($dialog.Content.Children[1].Text -ceq (Join-Path $destination 'operation-parent')) 'Switching back did not append the current directory name to the edited parent.'
    } finally { $dialog.Close() }
    $dialog = $dialogType.GetConstructors($flags)[0].Invoke([object[]] @($true, [string] $root, $null, [string] 'example.txt', $true))
    try {
        Assert-True ($dialog.Title -ceq 'Relocate file' -and $dialog.Content.Children[2].Children[1].Content -ceq 'Relocate') 'The file relocation dialog has incorrect labels.'
        $dialog.Content.Children[0].Children[1].IsChecked = $true
        Assert-True ($dialog.Content.Children[1].Text -ceq (Join-Path $root 'example.txt')) 'The file relocation dialog did not retain the extension.'
    } finally { $dialog.Close() }
    $dialog = $dialogType.GetConstructors($flags)[0].Invoke([object[]] @($false, [string] 'example', $null, $null, $false))
    try {
        Assert-True ($dialog.Title -ceq 'Rename directory' -and $dialog.Content.Children[0].Text -ceq 'Directory name' -and $dialog.Content.Children[2].Children[1].Content -ceq 'Rename') 'The rename dialog has incorrect labels.'
    } finally { $dialog.Close() }
    'Directory location dialog tests passed.'
} finally { $application.Shutdown() }