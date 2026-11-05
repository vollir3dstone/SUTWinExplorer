. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-content-actions-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current
$savedClipboard = [System.Windows.Clipboard]::GetDataObject()

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'notes')
    [System.IO.File]::WriteAllText((Join-Path $directory 'exact.bin'), 'other')
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $menuActionOrder = @($view.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($view, @()) | ForEach-Object { $_.Id })
    $window = [System.Windows.Window]::new()
    try {
        $window.ShowInTaskbar = $false
        $window.Left = -20000
        $window.Top = -20000
        $window.Width = 800
        $window.Height = 500
        $window.Content = $view
        $window.Show()
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $list = $view.FindName('FileList')
        $ownerHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $showMenu = $view.GetType().GetMethod('ShowMenu', $viewFlags)
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $otherFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'exact.bin') })[0]
        Assert-True ($probe.Ready -and $null -ne $notesMenuRow -and $null -ne $otherFileRow) "ContentView action fixture did not load: $($probe.Error)"
        $unfilteredMenu = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path (Join-Path $directory 'notes.txt') -Generic | ConvertFrom-Json).Menu
        $notepadEntries = @($unfilteredMenu | Where-Object { $_.Verb -eq 'ANotepad++64' })
        $viewerEntries = @($unfilteredMenu | Where-Object { $_.Verb -eq 'view SUTTextViewer' })
        $list.SelectedItems.Clear()
        $list.SelectedItems.Add($notesMenuRow) | Out-Null
        $list.SelectedItems.Add($otherFileRow) | Out-Null
        $selectedPaths = @($notesMenuRow.Entry.FullPath, $otherFileRow.Entry.FullPath)
        foreach ($operation in @('Link', 'Copy', 'Move')) {
            $view.FindName("${operation}MarkItemButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $workflowType = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true)
            $workflow = $workflowType.GetProperty('Shared').GetValue($null)
            $preparedPaths = @($workflow.PreparedPaths)
            Assert-True ($preparedPaths.Count -eq 2 -and @($selectedPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "$operation did not stage all selected paths."
            $view.FindName("${operation}AbortButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $multiPaths = @($notesMenuRow.Entry.FullPath, $otherFileRow.Entry.FullPath)
        $list.SelectedItems.Clear()
        $list.SelectedItems.Add($notesMenuRow) | Out-Null
        $list.SelectedItems.Add($otherFileRow) | Out-Null
        foreach ($selection in @($null, 'LinkMarkItem', 'LinkAbort', 'CopyMarkItem', 'CopyAbort', 'MoveMarkItem', 'MoveAbort')) {
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            if ($null -ne $selection) { $menuProbe.SelectCommandId = Get-ActionCommandId $selection }
            try {
                $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                Assert-True (Test-BaseMenu $menuProbe) 'Multiple files did not show the Base Menu.'
                Assert-True (($menuProbe.States[0] -band 3) -eq 0 -and ($menuProbe.States[2] -band 3) -eq 0 -and ($menuProbe.States[3] -band 3) -eq 0 -and ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'Rename')] -band 3) -ne 0) 'Multiple file selection actions have incorrect states.'
                if ($null -ne $selection) { Assert-True ($menuProbe.SelectIndex -ge 0 -and ($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0) "Multi-file command $selection was disabled." }
            } finally { $menuProbe.Dispose() }
            if ($selection -in @('LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem')) {
                $operation = $selection -replace 'MarkItem$', ''
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $preparedPaths = @($workflow.PreparedPaths)
                Assert-True ($workflow.IsPrepared -and $preparedPaths.Count -eq 2 -and
                    @($multiPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "Multi-file $operation mark item did not prepare both files."
            } elseif ($selection -in @('LinkAbort', 'CopyAbort', 'MoveAbort')) {
                $operation = $selection -replace 'Abort$', ''
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                Assert-True (-not $workflow.IsPrepared) "Multi-file $operation abort did not clear the workflow."
            }
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $notesMenuRow
        $originalClipboard = [System.Windows.Clipboard]::GetDataObject()
        try {
            foreach ($case in @(@{ Name = 'Name'; Expected = 'notes.txt' },
                                @{ Name = 'Path'; Expected = (Join-Path $directory 'notes.txt') })) {
                [System.Windows.Clipboard]::SetText('button action sentinel')
                $button = $view.FindName("$($case.Name)ClipboardCopyButton")
                Assert-True $button.IsEnabled "$($case.Name) clipboard copy button was disabled."
                $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                Assert-True ([System.Windows.Clipboard]::GetText() -ceq $case.Expected) "$($case.Name) clipboard copy button did not copy the selected value."
            }
            foreach ($selection in @($null, 'NameClipboardCopy', 'PathClipboardCopy', 'LinkMarkItem', 'LinkAbort', 'CopyMarkItem', 'CopyAbort', 'MoveMarkItem', 'MoveAbort', 'Rename')) {
                $buttonStates = @($standardActionIds |
                    ForEach-Object { $view.FindName($_ + 'Button').IsEnabled })
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                if ($null -ne $selection) { $menuProbe.SelectCommandId = Get-ActionCommandId $selection }
                try {
                    $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                    Assert-True (Test-BaseMenu $menuProbe) "The menu did not match the toolbar actions: $($menuProbe.Items -join ',')."
                    $openWithLabel = [SutShellMenuProbe]::OpenWithLabel()
                    Assert-True ($null -ne $openWithLabel -and $openWithLabel -notin $menuProbe.Items) 'The Shell Open With submenu is still present.'
                    $linkDropHereLabel = [SutShellMenuProbe]::LinkDropHereLabel()
                    Assert-True ($null -eq $linkDropHereLabel -or $linkDropHereLabel -notin $menuProbe.Items) 'A drag-and-drop-only Link Shell Extension command appeared in the file menu.'
                    foreach ($entry in $notepadEntries) {
                        Assert-True ($entry.Text -notin $menuProbe.Items) 'The blacklisted Notepad++ command appeared in the Base Menu.'
                    }
                    foreach ($entry in $viewerEntries) {
                        Assert-True ($entry.Text -in $menuProbe.Items) 'The unblacklisted SUTTextViewer command disappeared from the Base Menu.'
                    }
                    $deleteIndex = Get-MenuActionIndex $menuProbe 'Delete'
                    $renameIndex = Get-MenuActionIndex $menuProbe 'Rename'
                    Assert-True ($deleteIndex -eq $menuProbe.ItemCount - 1 -and $renameIndex -eq $deleteIndex - 2 -and
                        ($menuProbe.States[$renameIndex - 1] -band 0x800) -ne 0 -and ($menuProbe.States[$deleteIndex - 1] -band 0x800) -ne 0) 'Rename and Delete were not separated at the end of the Base Menu.'
                    for ($index = 0; $index -lt $standardActionIds.Count; $index++) {
                        $menuIndex = Get-MenuActionIndex $menuProbe $standardActionIds[$index]
                        if ($standardActionIds[$index] -match '^(Link|Copy|Move)' -and -not $buttonStates[$index]) {
                            Assert-True ($menuIndex -lt 0) "Disabled transfer action $($standardActionIds[$index]) was visible."
                        } else {
                            Assert-True ($menuIndex -ge 0 -and ((($menuProbe.States[$menuIndex] -band 3) -eq 0) -eq $buttonStates[$index])) "Menu state did not match $($standardActionIds[$index])."
                        }
                    }
                    if ($null -ne $selection) { Assert-True ($menuProbe.SelectIndex -ge 0 -and ($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0) "Command $selection was disabled." }
                } finally { $menuProbe.Dispose() }
                if ($selection -eq 'NameClipboardCopy') {
                    Assert-True ([System.Windows.Clipboard]::GetText() -ceq 'notes.txt') 'Name clipboard copy did not put the selected name on the clipboard.'
                } elseif ($selection -eq 'PathClipboardCopy') {
                    Assert-True ([System.Windows.Clipboard]::GetText() -ceq (Join-Path $directory 'notes.txt')) 'Path clipboard copy did not put the selected path on the clipboard.'
                } elseif ($selection -in @('LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem')) {
                    $operation = $selection -replace 'MarkItem$', ''
                    $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                    Assert-True ($workflow.IsPrepared -and @($workflow.PreparedPaths)[0] -ceq (Join-Path $directory 'notes.txt')) "$operation mark item did not prepare the selected file."
                } elseif ($selection -in @('LinkAbort', 'CopyAbort', 'MoveAbort')) {
                    $operation = $selection -replace 'Abort$', ''
                    $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                    Assert-True (-not $workflow.IsPrepared) "$operation abort did not clear the workflow."
                } elseif ($selection -eq 'Rename') {
                    Assert-True $notesMenuRow.IsEditing 'Rename did not start the inline editor.'
                    $null = $view.GetType().GetMethod('EndRename', $viewFlags).Invoke($view, [object[]] @([bool] $false))
                }
            }
        } finally {
            if ($null -eq $originalClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($originalClipboard, $true) }
        }
        $pasteSource = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-menu-source-' + [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.Directory]::CreateDirectory($pasteSource) | Out-Null
            foreach ($operation in @('Link', 'Copy', 'Move')) {
                $sourceFile = Join-Path $pasteSource "menu-$operation-test.txt"
                $destinationName = if ($operation -eq 'Link') { "menu-$operation-test.txt - Shortcut.lnk" } else { "menu-$operation-test.txt" }
                $destinationFile = Join-Path $directory $destinationName
                [System.IO.File]::WriteAllText($sourceFile, 'menu workflow test')
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $workflow.Prepare([string[]] @($sourceFile))
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectCommandId = Get-ActionCommandId "${operation}Execute"
                try {
                    $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                    Assert-True ($menuProbe.SelectIndex -ge 0 -and ($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0) "$operation execute was disabled."
                } finally { $menuProbe.Dispose() }
                Assert-True ([System.IO.File]::Exists($destinationFile) -and -not $workflow.IsPrepared) "$operation execute did not complete the prepared workflow."
                Assert-True (([System.IO.File]::Exists($sourceFile)) -eq ($operation -ne 'Move')) "$operation execute did not preserve the expected source state."
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $probe = [SutShellUiProbe]::new()
                $probe.List = $list
                $probe.AwaitAll = $true
                $probe.Frame = $frame
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(25)
                $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
                $timer.Start()
                try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
                Assert-True $probe.Ready "Rows did not reload after $operation execute: $($probe.Error)"
                $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
                $list.SelectedItem = $notesMenuRow
                Remove-Item -LiteralPath $destinationFile -Force
            }
        } finally {
            Remove-Item -LiteralPath $pasteSource -Recurse -Force -ErrorAction SilentlyContinue
        }
        $view.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        Wait-ListCount $list 3
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $folderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'Folder') })[0]
        Assert-True ($probe.Ready -and $null -ne $notesMenuRow -and $null -ne $folderRow) 'Mixed-selection action fixture did not load.'
        $list.SelectedItems.Clear()
        $list.SelectedItem = $folderRow
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'CopyMarkItem'
        try {
            $null = $showMenu.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject))
            $workflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
            Assert-True ($workflow.IsPrepared -and @($workflow.PreparedPaths).Count -eq 1 -and
                @($workflow.PreparedPaths)[0] -eq $folderRow.Entry.FullPath) 'Copy mark item did not prepare the selected directory.'
        } finally {
            $menuProbe.Dispose()
            $view.FindName('CopyAbortButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        foreach ($firstRow in @($notesMenuRow, $folderRow)) {
            $secondRow = if ($firstRow -eq $folderRow) { $notesMenuRow } else { $folderRow }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($firstRow) | Out-Null
            $list.SelectedItems.Add($secondRow) | Out-Null
            $mixedPaths = @($firstRow.Entry.FullPath, $secondRow.Entry.FullPath)
            foreach ($operation in @('Copy', 'Move')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectCommandId = Get-ActionCommandId "${operation}MarkItem"
                try { $null = $showMenu.Invoke($view, [object[]] @($firstRow.PSObject.BaseObject)) } finally { $menuProbe.Dispose() }
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $preparedPaths = @($workflow.PreparedPaths)
                Assert-True ($workflow.IsPrepared -and $preparedPaths.Count -eq 2 -and
                    @($mixedPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "Mixed-selection $operation did not prepare both items."
                $view.FindName("${operation}AbortButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $notesMenuRow
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'ItemClipboardCopy'
        try {
            $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
            Assert-True ($menuProbe.SelectIndex -ge 0 -and [System.Windows.Clipboard]::ContainsFileDropList() -and
                (Join-Path $directory 'notes.txt') -in @([System.Windows.Clipboard]::GetFileDropList())) 'Item clipboard copy did not execute from the Base Menu.'
        } finally { $menuProbe.Dispose() }
        $clipboardDestination = Join-Path $directory 'clipboard-destination'
        [System.IO.Directory]::CreateDirectory($clipboardDestination) | Out-Null
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $clipboardDestination))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick({ if ($view.FindName('ItemClipboardPasteButton').IsEnabled -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $view.FindName('ItemClipboardPasteButton').IsEnabled 'Item clipboard paste did not become available in the destination.'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'ItemClipboardPaste'
        try {
            $showMenuCore = $view.GetType().GetMethod('ShowMenuCore', $viewFlags)
            $null = $showMenuCore.Invoke($view, [object[]] @($null, $false))
            Assert-True ($menuProbe.SelectIndex -ge 0 -and [System.IO.File]::Exists((Join-Path $clipboardDestination 'notes.txt'))) 'Item clipboard paste did not execute from the background Base Menu.'
        } finally { $menuProbe.Dispose() }
    } finally { $window.Close() }
    'ContentView action interaction tests passed.'
} finally {
    foreach ($operation in @('Link', 'Copy', 'Move')) {
        $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null).Abort()
    }
    if ($null -eq $savedClipboard) { [System.Windows.Clipboard]::Clear() }
    else { [System.Windows.Clipboard]::SetDataObject($savedClipboard, $true) }
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}