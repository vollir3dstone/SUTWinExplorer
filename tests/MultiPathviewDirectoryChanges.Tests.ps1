$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))

function Pump([int] $milliseconds) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
}

function Wait-Until([scriptblock] $condition, [string] $message) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (& $condition) -and [DateTime]::UtcNow -lt $deadline) { Pump 100 }
    if (-not (& $condition)) { throw $message }
}

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-rename-' + [guid]::NewGuid().ToString('N'))
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
try {
    [void] [IO.Directory]::CreateDirectory($root)
    $storeType = $assembly.GetType('SUTWinExplorer.UseCaseStore', $true)
    $store = [Activator]::CreateInstance($storeType, [object[]] @([string] (Join-Path $root 'use-cases'), [string] 'test'))
    $useCase = $storeType.GetMethod('LoadOrCreate').Invoke($store, @())
    $application.GetType().GetMethod('SetActiveUseCase', $flags).Invoke($application, [object[]] @($store, $useCase))
    $parentPath = Join-Path $root 'ancestor'
    $childPath = Join-Path $parentPath 'child'
    [void] [IO.Directory]::CreateDirectory($childPath)
    [IO.File]::WriteAllText((Join-Path $childPath 'child.txt'), 'content')
    $mainWindow = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.MainWindow', $true))
    try {
        $addPaneview = $mainWindow.GetType().GetMethod('AddPaneview', $flags)
        $addPaneview.Invoke($mainWindow, [object[]] @([string] $root, $true, $null, $false))
        $addPaneview.Invoke($mainWindow, [object[]] @([string] $childPath, $false, $null, $false))
        $tabs = $mainWindow.FindName('ExplorerTabs')
        $fixedView = $tabs.Items[1].Content
        $fixedView.GetType().GetMethod('CommitCustomName', $flags).Invoke($fixedView, [object[]] @([string] 'Custom tab'))
        $fixedContent = $fixedView.FindName('DirectoryContent')
        $fixedCache = $fixedContent.GetType().GetField('_directoryCache', $flags).GetValue($fixedContent)
        $fixedItems = $fixedCache.GetType().GetField('_items', $flags)
        Wait-Until { $null -ne $fixedItems.GetValue($fixedCache) } 'The fixed Pathview did not load.'
        Wait-Until { $null -eq $fixedContent.GetType().GetField('_refreshCancellation', $flags).GetValue($fixedContent) } 'The fixed Pathview snapshot did not finish.'
        Pump 1000
        $fixedGeneration = $fixedCache.GetType().GetField('_generation', $flags).GetValue($fixedCache)
        $fixedInitialItems = $fixedItems.GetValue($fixedCache)
        $renamedChild = Join-Path $parentPath 'renamed-child'
        [IO.Directory]::Move($childPath, $renamedChild)
        Wait-Until { $fixedView.CurrentPath -ceq $renamedChild } 'An external directory rename was not propagated.'
        $savedUseCase = $storeType.GetMethod('Load').Invoke($store, @())
        if ($savedUseCase.Pathviews[0].Path -cne $renamedChild -or $savedUseCase.Pathviews[0].Name -cne 'Custom tab') { throw 'The renamed path or custom name was not persisted in the use case.' }
        if ($tabs.Items[1].Header.Children[0].Text -cne 'Custom tab') { throw 'The custom tab name changed.' }
        if ($fixedCache.GetType().GetField('_generation', $flags).GetValue($fixedCache) -ne $fixedGeneration -or -not [object]::ReferenceEquals($fixedInitialItems, $fixedItems.GetValue($fixedCache))) { throw 'The ancestor rename invalidated the child Pathview cache.' }
        if ($fixedView.GetType().GetField('_enumerationDirty', $flags).GetValue($fixedView) -or $fixedView.GetType().GetField('_displayDirty', $flags).GetValue($fixedView)) { throw 'The ancestor rename dirtied the child Pathview.' }

        $destination = Join-Path $root 'destination'
        [void] [IO.Directory]::CreateDirectory($destination)
        $moved = [System.Collections.Generic.List[string]]::new()
        $movedDirectories = [System.Collections.Generic.List[System.ValueTuple[string,string]]]::new()
        $move = $assembly.GetType('SUTWinExplorer.SutShell', $true).GetMethod('MoveWithDirectoryChanges', $flags -bor [Reflection.BindingFlags]::Static)
        $move.Invoke($null, [object[]] @([string[]] @($renamedChild), [string] $destination, [IntPtr]::Zero, $moved, $movedDirectories))
        if ($movedDirectories.Count -ne 1 -or $movedDirectories[0].Item1 -cne $renamedChild -or $movedDirectories[0].Item2 -cne (Join-Path $destination 'renamed-child')) { throw 'The shell move did not report the actual directory source and destination.' }
        $mainWindow.GetType().GetMethod('Pathview_DirectoryRenamed', $flags).Invoke($mainWindow, [object[]] @([string] $movedDirectories[0].Item1, [string] $movedDirectories[0].Item2))
        $movedChild = $movedDirectories[0].Item2
        if ($fixedView.CurrentPath -cne $movedChild -or $storeType.GetMethod('Load').Invoke($store, @()).Pathviews[0].Path -cne $movedChild) { throw 'The moved Pathview path was not saved.' }
        if ($fixedCache.GetType().GetField('_generation', $flags).GetValue($fixedCache) -ne $fixedGeneration -or -not [object]::ReferenceEquals($fixedInitialItems, $fixedItems.GetValue($fixedCache))) { throw 'The move invalidated the child Pathview cache.' }
        $treeRoot = @($fixedView.FindName('ActivePathTree').ItemsSource)[0]
        $treeNode = $treeRoot
        foreach ($segment in [IO.Path]::GetRelativePath($treeRoot.Path, $movedChild).Split([IO.Path]::DirectorySeparatorChar)) {
            $nextPath = Join-Path $treeNode.Path $segment
            $treeNode = @($treeNode.Children | Where-Object { $_.Path -ceq $nextPath })[0]
            if ($null -eq $treeNode) { throw 'The active tree route was not reparented after the move.' }
        }

        $operationParent = Join-Path $root 'operation-parent'
        $operationChild = Join-Path $operationParent 'child'
        [void] [IO.Directory]::CreateDirectory($operationChild)
        [IO.File]::WriteAllText((Join-Path $operationChild 'retained.txt'), 'content')
        $addPaneview.Invoke($mainWindow, [object[]] @([string] $operationParent, $false, $null, $false))
        $addPaneview.Invoke($mainWindow, [object[]] @([string] $operationChild, $false, $null, $false))
        $parentView = $tabs.Items[2].Content
        $childView = $tabs.Items[3].Content
        $childView.GetType().GetMethod('CommitCustomName', $flags).Invoke($childView, [object[]] @([string] 'Child custom'))
        $childContent = $childView.FindName('DirectoryContent')
        $childCache = $childContent.GetType().GetField('_directoryCache', $flags).GetValue($childContent)
        $childItems = $childCache.GetType().GetField('_items', $flags)
        $childGenerationField = $childCache.GetType().GetField('_generation', $flags)
        Wait-Until { $null -ne $childItems.GetValue($childCache) -and $null -eq $childContent.GetType().GetField('_refreshCancellation', $flags).GetValue($childContent) } 'The child Pathview did not load.'
        Pump 500
        $childItemsBefore = $childItems.GetValue($childCache)
        $childGeneration = $childGenerationField.GetValue($childCache)
        if (-not $parentView.FindName('RenameCurrentDirectoryButton').IsEnabled -or -not $parentView.FindName('RelocateCurrentDirectoryButton').IsEnabled) { throw 'The current-directory actions are not enabled.' }
        $moveMarkButton = $parentView.FindName('MoveMarkCurrentDirectoryButton')
        $childMoveMarkButton = $childView.FindName('MoveMarkCurrentDirectoryButton')
        $moveWorkflow = $assembly.GetType('SUTWinExplorer.MoveWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $copyWorkflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $linkWorkflow = $assembly.GetType('SUTWinExplorer.LinkWorkflowState', $true).GetProperty('Shared').GetValue($null)
        if (-not $moveMarkButton.IsEnabled -or $moveMarkButton.Content -cne 'Move🠝') { throw 'The current-directory Move mark item button is not available.' }
        $moveMarkButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        if (-not $moveWorkflow.IsPrepared -or @($moveWorkflow.PreparedPaths).Count -ne 1 -or $moveWorkflow.PreparedPaths[0] -cne $operationParent -or $moveMarkButton.IsEnabled -or $childMoveMarkButton.IsEnabled) { throw 'The header button did not prepare the current directory or update other Pathviews.' }
        $moveWorkflow.Abort()
        if (-not $moveMarkButton.IsEnabled -or -not $childMoveMarkButton.IsEnabled) { throw 'The header buttons did not recover after Move abort.' }
        foreach ($workflow in @($linkWorkflow, $copyWorkflow)) {
            $workflow.Prepare([string[]] @($operationParent))
            if ($moveMarkButton.IsEnabled -or $childMoveMarkButton.IsEnabled) { throw 'A prepared transfer did not disable the header buttons.' }
            $workflow.Abort()
        }
        if ($parentView.FindName('RelocateCurrentDirectoryButton').Content -cne 'Relocate...') { throw 'The relocation button has an incorrect label.' }

        $parentView.GetType().GetMethod('RenameCurrentDirectory', $flags).Invoke($parentView, [object[]] @([string] 'renamed-parent'))
        $renamedParent = Join-Path $root 'renamed-parent'
        $renamedOperationChild = Join-Path $renamedParent 'child'
        if ($parentView.CurrentPath -cne $renamedParent -or $childView.CurrentPath -cne $renamedOperationChild) { throw 'The internal rename did not update both Pathviews.' }
        if ($tabs.Items[2].Header.Children[0].Text -notlike '*renamed-parent' -or $tabs.Items[3].Header.Children[0].Text -cne 'Child custom') { throw 'The internal rename did not update default and custom tab labels correctly.' }
        $savedUseCase = $storeType.GetMethod('Load').Invoke($store, @())
        if ($savedUseCase.Pathviews[1].Path -cne $renamedParent -or $savedUseCase.Pathviews[2].Path -cne $renamedOperationChild -or $savedUseCase.Pathviews[2].Name -cne 'Child custom') { throw 'The internal rename did not persist both Pathviews.' }
        if ($childGenerationField.GetValue($childCache) -ne $childGeneration -or -not [object]::ReferenceEquals($childItemsBefore, $childItems.GetValue($childCache))) { throw 'The internal ancestor rename re-enumerated the child.' }

        $parentView.GetType().GetMethod('RelocateCurrentDirectory', $flags).Invoke($parentView, [object[]] @([string] $destination, $false))
        $movedParent = Join-Path $destination 'renamed-parent'
        $movedOperationChild = Join-Path $movedParent 'child'
        if ($parentView.CurrentPath -cne $movedParent -or $childView.CurrentPath -cne $movedOperationChild) { throw 'The internal move did not update both Pathviews.' }
        $savedUseCase = $storeType.GetMethod('Load').Invoke($store, @())
        if ($savedUseCase.Pathviews[1].Path -cne $movedParent -or $savedUseCase.Pathviews[2].Path -cne $movedOperationChild) { throw 'The internal move did not persist both paths.' }
        if ($childGenerationField.GetValue($childCache) -ne $childGeneration -or -not [object]::ReferenceEquals($childItemsBefore, $childItems.GetValue($childCache))) { throw 'The internal ancestor move re-enumerated the child.' }

        $namedDestination = Join-Path $root 'relocated-and-renamed'
        $parentView.GetType().GetMethod('RelocateCurrentDirectory', $flags).Invoke($parentView, [object[]] @([string] $namedDestination, $true))
        $movedParent = $namedDestination
        $movedOperationChild = Join-Path $movedParent 'child'
        if ($parentView.CurrentPath -cne $movedParent -or $childView.CurrentPath -cne $movedOperationChild -or -not [IO.Directory]::Exists($movedOperationChild)) { throw 'Relocation with a new name did not update both Pathviews.' }
        $savedUseCase = $storeType.GetMethod('Load').Invoke($store, @())
        if ($savedUseCase.Pathviews[1].Path -cne $movedParent -or $savedUseCase.Pathviews[2].Path -cne $movedOperationChild -or $savedUseCase.Pathviews[2].Name -cne 'Child custom') { throw 'Relocation with a new name did not persist both paths and the custom name.' }
        if ($childGenerationField.GetValue($childCache) -ne $childGeneration -or -not [object]::ReferenceEquals($childItemsBefore, $childItems.GetValue($childCache))) { throw 'Relocation with a new name re-enumerated the child.' }

        $sameParentDestination = Join-Path $root 'renamed-in-place'
        $parentView.GetType().GetMethod('RelocateCurrentDirectory', $flags).Invoke($parentView, [object[]] @([string] $sameParentDestination, $true))
        $movedParent = $sameParentDestination
        $movedOperationChild = Join-Path $movedParent 'child'
        if ($parentView.CurrentPath -cne $movedParent -or $childView.CurrentPath -cne $movedOperationChild) { throw 'Relocation with a new name in the same parent did not update both Pathviews.' }
        if ($childGenerationField.GetValue($childCache) -ne $childGeneration -or -not [object]::ReferenceEquals($childItemsBefore, $childItems.GetValue($childCache))) { throw 'Relocation in the same parent re-enumerated the child.' }

        $renameFailed = $false
        try {
            $parentView.GetType().GetMethod('RenameCurrentDirectory', $flags).Invoke($parentView, [object[]] @([string] 'invalid/name'))
        } catch { $renameFailed = $true }
        if (-not $renameFailed) { throw 'Invalid rename unexpectedly succeeded.' }
        if ($parentView.GetType().GetField('_observersSuspended', $flags).GetValue($parentView) -or $childView.GetType().GetField('_observersSuspended', $flags).GetValue($childView)) { throw 'Observers were not resumed after a failed rename.' }
        [IO.File]::WriteAllText((Join-Path $movedOperationChild 'after-failure.txt'), 'content')
        Wait-Until { $childView.GetType().GetField('_enumerationDirty', $flags).GetValue($childView) } 'The child observer was not restored after failure.'

        $coordinator = $mainWindow.GetType().GetMethod('RunDirectoryOperation', $flags)
        $action = [Action] { [IO.File]::WriteAllText((Join-Path $movedParent 'during-gap.txt'), 'content') }.GetNewClosure()
        $coordinator.Invoke($mainWindow, [object[]] @($action))
        if (-not $parentView.GetType().GetField('_enumerationDirty', $flags).GetValue($parentView)) { throw 'A directory change during observer suspension was not reconciled.' }

        $canceled = [Action] { throw [OperationCanceledException]::new('Canceled') }
        try { $coordinator.Invoke($mainWindow, [object[]] @($canceled)) } catch { }
        if ($parentView.GetType().GetField('_observersSuspended', $flags).GetValue($parentView) -or $childView.GetType().GetField('_observersSuspended', $flags).GetValue($childView)) { throw 'Observers were not resumed after cancellation.' }

        $browseView = $tabs.Items[0].Content
        $browseView.Navigate($destination, $null, $null, $null)
        $moveMarkButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $browseContent = $browseView.FindName('DirectoryContent')
        $transferActions = $browseContent.GetType().GetMethod('CreateContentTransferActions', $flags).Invoke($browseContent, [object[]] @([string] $destination))
        @($transferActions | Where-Object { $_.Id -eq 'MoveExecute' })[0].Invoke.Invoke()
        $executedParent = Join-Path $destination 'renamed-in-place'
        if ($moveWorkflow.IsPrepared -or $parentView.CurrentPath -cne $executedParent -or $childView.CurrentPath -cne (Join-Path $executedParent 'child') -or -not [IO.Directory]::Exists($executedParent)) { throw 'Executing the header-prepared Move in another Pathview did not move and update the directory.' }

        $closeChild = [Action] { $childView.GetType().GetMethod('Close', $flags).Invoke($childView, @()) }.GetNewClosure()
        $coordinator.Invoke($mainWindow, [object[]] @($closeChild))
        if ($null -ne $childContent.GetType().GetField('_directoryObserver', $flags).GetValue($childContent)) { throw 'A closed Pathview resumed its observers.' }

        $browseView.Navigate([IO.Path]::GetPathRoot($root), $null, $null, $null)
        if ($browseView.FindName('RenameCurrentDirectoryButton').IsEnabled -or $browseView.FindName('RelocateCurrentDirectoryButton').IsEnabled -or $browseView.FindName('MoveMarkCurrentDirectoryButton').IsEnabled) { throw 'Directory operations must be disabled for drive roots.' }
    } finally { $mainWindow.Close() }
    Write-Output 'MultiPathview directory change tests passed.'
} finally {
    foreach ($operation in @('Link', 'Copy', 'Move')) {
        $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null).Abort()
    }
    $application.Shutdown()
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
