$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Show-Configuration($window, [bool] $apply, [bool[]] $values) {
    $result = @{ Seen = $false; Error = $null; Initial = $null }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $timer.add_Tick({
        $dialog = @([System.Windows.Application]::Current.Windows | Where-Object { $_.Title -eq 'Configuration' -and $_.IsVisible }) | Select-Object -First 1
        if ($null -eq $dialog) { return }
        $timer.Stop()
        try {
            $result.Seen = $true
            $checkboxes = @($dialog.Content.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
            Assert-True ($checkboxes.Count -eq 3) 'Configuration dialog does not contain three checkboxes.'
            Assert-True (($checkboxes.Name -join '|') -ceq 'DirectoryRowActionButtonsCheckBox|DirectoryColumnActionButtonsCheckBox|SelectedItemsActionButtonsCheckBox' -and
                ($checkboxes.Content -join '|') -ceq 'Show directory row action buttons|Show directory column action buttons|Show selected items action buttons') 'Configuration labels or checkbox order are incorrect.'
            $result.Initial = @($checkboxes | ForEach-Object { $_.IsChecked })
            for ($index = 0; $index -lt 3; $index++) { $checkboxes[$index].IsChecked = $values[$index] }
            if ($apply) {
                $button = @($dialog.Content.Children[-1].Children | Where-Object { $_.Name -eq 'ApplyButton' })[0]
                $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            } else { $dialog.Close() }
        } catch { $result.Error = $_; $dialog.Close() }
    }.GetNewClosure())
    $timer.Start()
    try { $window.FindName('ConfigurationButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
    finally { $timer.Stop() }
    if ($result.Error) { throw $result.Error }
    Assert-True $result.Seen 'Configuration dialog was not displayed.'
    return ,$result.Initial
}

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$operations = [System.Collections.Generic.List[System.Windows.Threading.DispatcherOperation]]::new()
$posted = [System.Windows.Threading.DispatcherHookEventHandler] { param($sender, $eventArgs) $operations.Add($eventArgs.Operation) }.GetNewClosure()
$dispatcher.Hooks.add_OperationPosted($posted)
try { $application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true)) }
finally { $dispatcher.Hooks.remove_OperationPosted($posted) }
foreach ($operation in $operations) { [void] $operation.Abort() }
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-configuration-ui-' + [guid]::NewGuid().ToString('N'))
$window = $null
try {
    $firstPath = Join-Path $directory 'first'
    $secondPath = Join-Path $directory 'second'
    [void] [IO.Directory]::CreateDirectory($firstPath)
    [void] [IO.Directory]::CreateDirectory($secondPath)
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $useCaseStore = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.UseCaseStore', $true), [object[]] @([string] $directory, 'default'))
    $application.GetType().GetMethod('SetActiveUseCase', $flags).Invoke($application, [object[]] @($useCaseStore, $useCaseStore.LoadOrCreate()))
    $configurationStore = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ExplorerConfigurationStore', $true), [object[]] @([string] $directory))
    $application.GetType().GetProperty('ConfigurationStore', $flags).SetValue($application, $configurationStore)
    $application.GetType().GetProperty('Configuration', $flags).SetValue($application, $configurationStore.LoadOrCreate())

    $window = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.MainWindow', $true))
    $rendered = $window.GetType().GetMethod('MainWindow_ContentRendered', $flags)
    $window.remove_ContentRendered([EventHandler]::CreateDelegate([EventHandler], $window, $rendered))
    $add = $window.GetType().GetMethod('AddPaneview', $flags)
    $add.Invoke($window, [object[]] @([string] $directory, $true, $null, $false))
    $add.Invoke($window, [object[]] @([string] $firstPath, $false, $null, $false))
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Show()
    $window.UpdateLayout()
    $tabs = $window.FindName('ExplorerTabs')
    $browse = $tabs.Items[0].Content
    $fixed = $tabs.Items[1].Content
    $gear = $window.FindName('ConfigurationButton')
    $useCases = $window.FindName('UseCasesButton')
    Assert-True ($gear.TranslatePoint([System.Windows.Point]::new(0, 0), $window).X -lt $useCases.TranslatePoint([System.Windows.Point]::new(0, 0), $window).X) 'Configuration button is not before Use cases.'

    $initial = Show-Configuration $window $false @($true, $true, $true)
    Assert-True (-not $initial[0] -and -not $initial[1] -and -not $initial[2] -and
        -not $browse.ShowDirectoryRowActionButtons -and -not $configurationStore.Load().Interface.ShowDirectoryRowActionButtons) 'Cancel changed the configuration.'
    $initial = Show-Configuration $window $true @($true, $false, $true)
    Assert-True (-not $initial[0] -and -not $initial[1] -and -not $initial[2]) "Dialog did not load the saved values: $($initial -join ',')."
    foreach ($view in @($browse, $fixed)) {
        Assert-True ($view.ShowDirectoryRowActionButtons -and -not $view.ShowDirectoryColumnActionButtons -and $view.ShowSelectedItemsActionButtons) 'Saved configuration was not applied to an open Pathview.'
    }
    $saved = $configurationStore.Load()
    Assert-True ($saved.Interface.ShowDirectoryRowActionButtons -and -not $saved.Interface.ShowDirectoryColumnActionButtons -and $saved.Interface.ShowSelectedItemsActionButtons) 'Dialog values were not persisted.'
    $application.GetType().GetProperty('Configuration', $flags).SetValue($application, $configurationStore.Load())
    $add.Invoke($window, [object[]] @([string] $secondPath, $false, $null, $false))
    $newView = $tabs.Items[2].Content
    Assert-True ($newView.ShowDirectoryRowActionButtons -and -not $newView.ShowDirectoryColumnActionButtons -and $newView.ShowSelectedItemsActionButtons) 'New Pathview did not receive saved settings.'
    $initial = Show-Configuration $window $false @($false, $true, $false)
    Assert-True ($initial[0] -and -not $initial[1] -and $initial[2] -and $configurationStore.Load().Interface.ShowDirectoryRowActionButtons) 'Reopened dialog or Cancel did not preserve saved settings.'
    'Configuration dialog tests passed.'
} finally {
    if ($null -ne $window) { $window.Close() }
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}