$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))

function Wait-Until([scriptblock] $condition, [string] $message) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (& $condition) -and [DateTime]::UtcNow -lt $deadline) {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    }
    if (-not (& $condition)) { throw $message }
}

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-browse-settings-' + [guid]::NewGuid().ToString('N'))
$window = $null
try {
    $fixedPath = Join-Path $root 'fixed'
    $childPath = Join-Path $fixedPath 'child'
    $otherPath = Join-Path $fixedPath 'other'
    $doubleClickPath = Join-Path $fixedPath 'double-click'
    [void] [IO.Directory]::CreateDirectory($childPath)
    [void] [IO.Directory]::CreateDirectory($otherPath)
    [void] [IO.Directory]::CreateDirectory($doubleClickPath)
    [IO.File]::WriteAllText((Join-Path $fixedPath 'small.txt'), 'a')
    [IO.File]::WriteAllText((Join-Path $fixedPath '.middle.txt'), 'aa')
    [IO.File]::WriteAllText((Join-Path $fixedPath 'large.txt'), 'aaa')
    [IO.File]::WriteAllText((Join-Path $fixedPath 'ignored.png'), 'aaaa')
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $storeType = $assembly.GetType('SUTWinExplorer.UseCaseStore', $true)
    $store = [Activator]::CreateInstance($storeType, [object[]] @([string] (Join-Path $root 'use-cases'), [string] 'test'))
    $useCase = $storeType.GetMethod('LoadOrCreate').Invoke($store, @())
    $application.GetType().GetMethod('SetActiveUseCase', $flags).Invoke($application, [object[]] @($store, $useCase))
    $window = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.MainWindow', $true))
    $add = $window.GetType().GetMethod('AddPaneview', $flags)
    $add.Invoke($window, [object[]] @([string] $root, $true, $null, $false))
    $add.Invoke($window, [object[]] @([string] $fixedPath, $false, $null, $false))
    $add.Invoke($window, [object[]] @([string] $childPath, $false, $null, $false))
    $tabs = $window.FindName('ExplorerTabs')
    $browse = $tabs.Items[0].Content
    $fixed = $tabs.Items[1].Content
    $otherFixed = $tabs.Items[2].Content
    $tabs.SelectedItem = $tabs.Items[2]
    $tabs.SelectedItem = $tabs.Items[0]
    $shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
    $staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
    $scheduledPaths = @($shell.GetField('_openOverlayDirectories', $staticFlags).GetValue($null))
    $activePath = $shell.GetField('_activeOverlayDirectory', $staticFlags).GetValue($null)
    if ($activePath -ne $root -or ($scheduledPaths -join '|') -ne (@($root, $childPath, $fixedPath) -join '|')) {
        throw "Overlay tab priority did not follow actual selections: active=$activePath, order=$($scheduledPaths -join '|')."
    }
    $source = $fixed.FindName('DirectoryContent')
    $destination = $browse.FindName('DirectoryContent')
    $fixed.FindName('HideInternalSubdirectoriesCheckBox').GetCheckBox().IsChecked = $false
    $source.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked = $false
    $source.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $true
    $source.FindName('NamePatternTextBox').Text = '*.txt'
    $sourceSort = $source.FindName('SortOrderEditor')
    $sourceSort.Select(5)
    $sourceSort.Select(5)
    $sourceSort.Child.Children[2].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $destination.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked = $true
    $destination.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
    $destination.FindName('NamePatternTextBox').Text = '*.png'

    $fixed.GetType().GetMethod('PathviewActionButton_Click', $flags).Invoke($fixed, [object[]] @($null, $null))
    if ($tabs.SelectedItem.Content -ne $browse -or $browse.CurrentPath -cne $fixedPath) { throw 'Browse did not select the fixed location in BROWSE.' }
    if ($browse.FindName('HideSiblingsCheckBox').IsChecked -ne $true -or
        $browse.FindName('HideInternalCheckBox').IsChecked -ne $false -or
        $destination.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked -ne $false -or
        $destination.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked -ne $true -or
        $destination.FindName('NamePatternTextBox').Text -cne '*.txt') { throw 'Browse did not copy all four filters.' }
    $destinationSort = $destination.FindName('SortOrderEditor')
    $expectedSort = @($sourceSort.Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    $actualSort = @($destinationSort.Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    if ($actualSort -cne $expectedSort -or $destination.FindName('SizeSortIndicator').Visibility -ne 'Visible') { throw 'Browse did not copy the full sort order and indicator.' }
    $sortState = $destination.GetType().GetField('_sorting', $flags).GetValue($destination)
    $pairs = @($sortState.GetType().GetProperty('Pairs', $flags).GetValue($sortState))
    if ($pairs[0].Column -ne 'Size' -or $pairs[0].Criterion -ne 'Descending') { throw 'The copied sort order was not applied to the content.' }
    $snapshot = $destination.GetType().GetField('_snapshot', $flags)
    Wait-Until { $null -ne $snapshot.GetValue($destination) } 'The copied view did not finish loading.'
    $destination.GetType().GetMethod('CancelOverlayWait', $flags).Invoke($destination, @())
    $beforeOverlayCompletion = $snapshot.GetValue($destination)
    $overlayCompletion = [Threading.Tasks.TaskCompletionSource]::new([Threading.Tasks.TaskCreationOptions]::RunContinuationsAsynchronously)
    $overlayCancellation = [Threading.CancellationTokenSource]::new()
    $null = $destination.GetType().GetMethod('RefreshAfterOverlaysAsync', $flags).Invoke($destination,
        [object[]] @($beforeOverlayCompletion, [string] $browse.CurrentPath, $overlayCompletion.Task, $overlayCancellation))
    $overlayCompletion.SetResult()
    Wait-Until { $null -ne $snapshot.GetValue($destination) -and -not [object]::ReferenceEquals($beforeOverlayCompletion, $snapshot.GetValue($destination)) } 'Overlay completion did not redisplay the current directory.'
    $actualNames = @($destination.FindName('FileList').Items | ForEach-Object { [IO.Path]::GetFileName($_.FullPath) }) -join ','
    if ($actualNames -cne 'large.txt,.middle.txt,small.txt') { throw "The copied filters or sort order produced unexpected rows: $actualNames" }

    $destination.FindName('NamePatternTextBox').Text = '*.changed'
    if ($source.FindName('NamePatternTextBox').Text -cne '*.txt') { throw 'Changing BROWSE changed the fixed view.' }
    $request = $fixed.GetType().GetMethod('RequestBrowseLocation', $flags)
    $request.Invoke($fixed, [object[]] @([string] $childPath, $null))
    if ($tabs.SelectedItem.Content -ne $otherFixed -or $destination.FindName('NamePatternTextBox').Text -cne '*.changed') { throw 'Selecting an existing fixed view changed BROWSE settings.' }
    $request.Invoke($fixed, [object[]] @([string] $otherPath, $null))
    if ($tabs.SelectedItem.Content -ne $browse -or $browse.CurrentPath -cne $otherPath -or
        $destination.FindName('NamePatternTextBox').Text -cne '*.txt') { throw 'Directory activation did not copy settings to BROWSE.' }
    $source.FindName('NamePatternTextBox').Text = ''
    $source.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked = $true
    $source.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
    $request.Invoke($fixed, [object[]] @([string] $otherPath, $null))
    if ($destination.FindName('NamePatternTextBox').Text -cne '' -or
        $destination.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked -ne $true -or
        $destination.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked -ne $false) { throw 'Changed settings were not copied on same-path navigation.' }
    $destination.FindName('NamePatternTextBox').Text = '*.keep'
    $navigate = $window.GetType().GetMethod('NavigateWithHistory', $flags)
    $navigate.Invoke($window, [object[]] @([string] $root, $null, $null, $null, $false, $null))
    if ($browse.CurrentPath -cne $root -or $destination.FindName('NamePatternTextBox').Text -cne '*.keep') { throw 'Ordinary navigation changed BROWSE settings.' }

    $source.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked = $false
    $source.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
    $source.FindName('NamePatternTextBox').Text = '*click*'
    $sourceSnapshot = $source.GetType().GetField('_snapshot', $flags)
    Wait-Until { $null -ne $sourceSnapshot.GetValue($source) } 'The fixed content did not finish loading.'
    $sourceList = $source.FindName('FileList')
    $row = @($sourceList.Items | Where-Object { $_.FullPath -ceq $doubleClickPath })[0]
    if ($null -eq $row) { throw 'The double-click test directory is not visible.' }
    $items = $sourceSnapshot.GetValue($source).GetType().GetProperty('Items', $flags).GetValue($sourceSnapshot.GetValue($source))
    $item = @($items | Where-Object { $_.GetType().GetProperty('FullPath', $flags).GetValue($_) -ceq $doubleClickPath })[0]
    $row.Entry = $item.GetType().GetProperty('Entry', $flags).GetValue($item)
    $sourceList.SelectedItem = $row
    $destination.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $true
    $destination.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked = $true
    $browse.FindName('HideInternalCheckBox').IsChecked = $true
    $source.GetType().GetMethod('FileList_MouseDoubleClick', $flags).Invoke($source, [object[]] @($sourceList, $null))
    $doubleClickSort = @($destinationSort.Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    if ($tabs.SelectedItem.Content -ne $browse -or $browse.CurrentPath -cne $doubleClickPath -or
        $browse.FindName('HideInternalCheckBox').IsChecked -ne $false -or
        $destination.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked -ne $false -or
        $destination.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked -ne $false -or
        $destination.FindName('NamePatternTextBox').Text -cne '*click*' -or $doubleClickSort -cne $expectedSort) {
        throw 'Double-clicking a directory did not transfer all view settings.'
    }

    $navigate.Invoke($window, [object[]] @([string] $fixedPath, $null, $null, $null, $false, $null))
    $hideDirectories = $destination.FindName('HideDirectoriesCheckBox').GetCheckBox()
    $hideInternal = $destination.FindName('HideInternalContentCheckBox').GetCheckBox()
    $pattern = $destination.FindName('NamePatternTextBox')
    $hideDirectories.IsChecked = $false
    $hideInternal.IsChecked = $false
    $pattern.Text = '*.txt'
    $destinationSort.Select(5)
    $destinationSort.Select(5)
    Wait-Until { $null -ne $snapshot.GetValue($destination) } 'The customized view did not finish loading.'
    $readyField = $destination.GetType().GetField('_snapshotReady', $flags)
    $probe = [pscustomobject] @{ Ready = $readyField.GetValue($destination); Events = 0; RefreshedDuringChange = $false }
    $observeChange = {
        $probe.Events++
        if (-not [object]::ReferenceEquals($probe.Ready, $readyField.GetValue($destination))) { $probe.RefreshedDuringChange = $true }
    }.GetNewClosure()
    $hideDirectories.add_Checked($observeChange)
    $hideInternal.add_Checked($observeChange)
    $pattern.add_TextChanged($observeChange)
    $destinationSort.add_Changed($observeChange)
    $destination.FindName('ResetViewButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    if ($probe.Events -ne 4 -or $probe.RefreshedDuringChange -or
        [object]::ReferenceEquals($probe.Ready, $readyField.GetValue($destination))) { throw 'Reset did not defer the refresh until all four controls changed.' }
    if ($hideDirectories.IsChecked -ne $true -or $hideInternal.IsChecked -ne $true -or $pattern.Text -cne '') { throw 'Reset did not restore the content filter defaults.' }
    $resetOrder = @($destinationSort.Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    if ($resetOrder -cne '0:Ascending,1:Ascending,2:Ascending,3:Ascending,4:Ascending,5:Ascending' -or
        $destination.FindName('NameSortIndicator').Visibility -ne 'Visible') { throw 'Reset did not restore the default sort order and indicator.' }
    if ($browse.FindName('HideInternalCheckBox').IsChecked -ne $false -or
        $source.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked -ne $false) { throw 'Reset changed another view or the tree filter.' }
    Wait-Until { $null -ne $snapshot.GetValue($destination) } 'The reset view did not finish loading.'
    $actualNames = @($destination.FindName('FileList').Items | ForEach-Object { [IO.Path]::GetFileName($_.FullPath) }) -join ','
    if ($actualNames -cne 'ignored.png,large.txt,small.txt') { throw "Reset produced unexpected rows: $actualNames" }

    $browse.FindName('HideInternalCheckBox').IsChecked = $true
    $hideDirectories.IsChecked = $true
    $hideInternal.IsChecked = $true
    $pattern.Text = '*.png'
    $destinationSort.Select(4)
    $destinationSort.Select(4)
    $pinSort = @($destinationSort.Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    $initialCount = $tabs.Items.Count
    $browse.GetType().GetMethod('PathviewActionButton_Click', $flags).Invoke($browse, [object[]] @($null, $null))
    $fixedSort = @($sourceSort.Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    if ($tabs.Items.Count -ne $initialCount -or $tabs.SelectedItem.Content -ne $fixed -or
        $fixed.FindName('HideInternalSubdirectoriesCheckBox').GetCheckBox().IsChecked -ne $true -or
        $source.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked -ne $true -or
        $source.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked -ne $true -or
        $source.FindName('NamePatternTextBox').Text -cne '*.png' -or $fixedSort -cne $pinSort) {
        throw 'Pin did not copy settings to the existing fixed view.'
    }

    $navigate.Invoke($window, [object[]] @([string] $otherPath, $null, $null, $null, $false, $null))
    $browse.FindName('HideInternalCheckBox').IsChecked = $false
    $hideDirectories.IsChecked = $false
    $hideInternal.IsChecked = $false
    $pattern.Text = '*.new'
    $browse.GetType().GetMethod('PathviewActionButton_Click', $flags).Invoke($browse, [object[]] @($null, $null))
    $newFixed = $tabs.SelectedItem.Content
    $newContent = $newFixed.FindName('DirectoryContent')
    $newSort = @($newContent.FindName('SortOrderEditor').Items | ForEach-Object { "$($_.Index):$($_.Direction)" }) -join ','
    if ($tabs.Items.Count -ne $initialCount + 1 -or $newFixed.CurrentPath -cne $otherPath -or
        $newFixed.FindName('HideInternalSubdirectoriesCheckBox').GetCheckBox().IsChecked -ne $false -or
        $newContent.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked -ne $false -or
        $newContent.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked -ne $false -or
        $newContent.FindName('NamePatternTextBox').Text -cne '*.new' -or $newSort -cne $pinSort) {
        throw 'Pin did not copy settings to the new fixed view.'
    }
    $newContent.FindName('NamePatternTextBox').Text = '*.independent'
    if ($pattern.Text -cne '*.new') { throw 'The pinned view shares mutable settings with BROWSE.' }
    'Browse settings tests passed.'
}
finally {
    if ($null -ne $window) { $window.Close() }
    $application.Shutdown()
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}