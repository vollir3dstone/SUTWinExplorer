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
        $list.SelectedItems.Add($notesMenuRow) | Out-Null
        $list.SelectedItems.Add($otherFileRow) | Out-Null
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'PathClipboardCopy'
        try { $null = $showMenu.Invoke($view, [object[]] @($null)) } finally { $menuProbe.Dispose() }
        Assert-True ($list.SelectedItems.Count -eq 0 -and [System.Windows.Clipboard]::GetText() -ceq $directory) 'The background menu did not clear the selection and use the active directory.'
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
        foreach ($selection in @($null, 'LinkMarkItem', 'AbortTransfer', 'CopyMarkItem', 'AbortTransfer', 'MoveMarkItem', 'AbortTransfer')) {
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
            } elseif ($selection -eq 'AbortTransfer') {
                foreach ($operation in @('Link', 'Copy', 'Move')) {
                    $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                    Assert-True (-not $workflow.IsPrepared) "Multi-file abort did not clear $operation."
                }
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
            foreach ($selection in @($null, 'NameClipboardCopy', 'PathClipboardCopy', 'LinkMarkItem', 'AbortTransfer', 'CopyMarkItem', 'AbortTransfer', 'MoveMarkItem', 'AbortTransfer', 'Rename')) {
                $visibleButtonActions = @('Properties', 'NameClipboardCopy', 'PathClipboardCopy', 'ItemClipboardCopy', 'LinkMarkItem', 'CopyMarkItem', 'MoveMarkItem', 'Rename', 'Delete')
                $buttonStates = @($visibleButtonActions |
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
                    Assert-True ($deleteIndex -eq $menuProbe.ItemCount - 1 -and $renameIndex -eq $deleteIndex - 3 -and
                        ($menuProbe.States[$renameIndex - 1] -band 0x800) -ne 0 -and ($menuProbe.States[$deleteIndex - 1] -band 0x800) -ne 0) 'Rename and Delete were not separated at the end of the Base Menu.'
                    for ($index = 0; $index -lt $visibleButtonActions.Count; $index++) {
                        $menuIndex = Get-MenuActionIndex $menuProbe $visibleButtonActions[$index]
                        Assert-True ($menuIndex -ge 0 -and ((($menuProbe.States[$menuIndex] -band 3) -eq 0) -eq $buttonStates[$index])) "Menu state did not match $($visibleButtonActions[$index])."
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
                } elseif ($selection -eq 'AbortTransfer') {
                    foreach ($operation in @('Link', 'Copy', 'Move')) {
                        $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                        Assert-True (-not $workflow.IsPrepared) "Abort did not clear $operation."
                    }
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
                $view.FindName("${operation}ExecuteButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
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
        $view.FindName('ItemClipboardPasteButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ([System.IO.File]::Exists((Join-Path $clipboardDestination 'notes.txt'))) 'Item clipboard paste did not execute from the toolbar.'
        $targetDirectory = Join-Path $clipboardDestination 'target'
        [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
        $view.GetType().GetMethod('RevealInsertedItems', $viewFlags).Invoke($view, [object[]] @(,[string[]] @($targetDirectory)))
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
        $targetRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq $targetDirectory })[0]
        Assert-True ($probe.Ready -and $null -ne $targetRow) 'Transfer destination row did not load.'
        $controller = $view.GetType().GetField('_contextMenu', $viewFlags).GetValue($view)
        $controllerShow = $controller.GetType().GetMethod('Show', $viewFlags)
        $controllerReset = $controller.GetType().GetMethod('Reset', $viewFlags)
        $createTransfers = $view.GetType().GetMethod('CreateContentTransferActions', $viewFlags)
        $menuClipboardFile = [string] (Join-Path $directory 'content-menu-paste.txt')
        [IO.File]::WriteAllText($menuClipboardFile, 'content menu paste')
        $escapedPath = $menuClipboardFile.Replace("'", "''")
        $script = "Add-Type -AssemblyName PresentationFramework; `$data = [System.Windows.DataObject]::new(); `$paths = [System.Collections.Specialized.StringCollection]::new(); `$null = `$paths.Add('$escapedPath'); `$data.SetFileDropList(`$paths); `$data.SetData('Preferred DropEffect', [IO.MemoryStream]::new([BitConverter]::GetBytes([uint32] 1))); [System.Windows.Clipboard]::SetDataObject(`$data, `$true)"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        & pwsh -NoProfile -STA -EncodedCommand $encoded
        Assert-True ($LASTEXITCODE -eq 0) 'Could not set external Copy clipboard data.'
        $menuType = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
        $factoryFlags = [Reflection.BindingFlags]'Static,NonPublic'
        $nativeBackground = $menuType.GetMethod('GetBackgroundMenu', $factoryFlags).Invoke($null, [object[]] @([string] $clipboardDestination, $ownerHandle))
        try { $nativeBackgroundVerbs = @(Get-ShellMenuVerbs $nativeBackground) }
        finally { ([IDisposable] $nativeBackground).Dispose() }
        Assert-True ('paste' -in $nativeBackgroundVerbs) "Native background menu did not expose paste: $($nativeBackgroundVerbs -join ',')."
        $backgroundBase = $menuType.GetMethod('GetBaseMenuForContext', $factoryFlags).Invoke($null, [object[]] @([string[]] @($clipboardDestination), $ownerHandle,
            $view.GetType().GetMethod('CreateActiveDirectoryMenuActions', $viewFlags).Invoke($view, @()), $true))
        try { $snapshot = $backgroundBase.GetType().GetMethod('CaptureSnapshot', $viewFlags).Invoke($backgroundBase, @()) }
        finally { ([IDisposable] $backgroundBase).Dispose() }
        $backgroundContent = $menuType.GetMethod('GetContentMenuWithTransferActions', $factoryFlags).Invoke($null, [object[]] @([string[]] @($clipboardDestination), $ownerHandle, $snapshot, $true, $null, $null, $null,
            $createTransfers.Invoke($view, [object[]] @([string] $clipboardDestination))))
        try { Assert-True ('paste' -notin @(Get-ShellMenuVerbs $backgroundContent)) "Native background paste was not filtered; original verbs=$($nativeBackgroundVerbs -join ',')." }
        finally { ([IDisposable] $backgroundContent).Dispose() }
        $clipboardWorkflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
        foreach ($background in @($false, $true)) {
            $target = if ($background) { $null } else { $targetRow.PSObject.BaseObject }
            if (-not $background) { $list.SelectedItem = $target }
            $clipboardWorkflow.Prepare([string[]] @($menuClipboardFile))
            $null = $controllerReset.Invoke($controller, @())
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try { $null = $controllerShow.Invoke($controller, [object[]] @($target, $ownerHandle, $true)) }
            finally { $menuProbe.Dispose() }
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectLabel = 'Item clipboard paste'
            try {
                $null = $controllerShow.Invoke($controller, [object[]] @($target, $ownerHandle, $true))
                Assert-True ($menuProbe.Items[0] -ceq 'Item clipboard paste' -and $menuProbe.SelectIndex -eq 0 -and
                    ($menuProbe.States[1] -band 0x800) -ne 0 -and $menuProbe.Items[2] -ceq 'Abort transfer' -and
                    $menuProbe.Items[3] -ceq 'Insert copy of marked item') "Incorrect clipboard content menu for background=$background`: items=$($menuProbe.Items -join '|'), index=$($menuProbe.SelectIndex), states=$($menuProbe.States -join ',')."
            } finally { $menuProbe.Dispose() }
            $destination = if ($background) { $clipboardDestination } else { $targetDirectory }
            Assert-True ([IO.File]::Exists((Join-Path $destination 'content-menu-paste.txt')) -and [IO.File]::Exists($menuClipboardFile) -and $clipboardWorkflow.IsPrepared) "Clipboard paste used the wrong destination or changed the prepared transfer for background=$background."
            $clipboardWorkflow.Abort()
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $probe = [SutShellUiProbe]::new()
            $probe.List = $list; $probe.AwaitAll = $true; $probe.Frame = $frame
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True $probe.Ready 'Content view did not reload after clipboard paste.'
        }
        [System.Windows.Clipboard]::SetText('no clipboard files')
        Assert-True (@($createTransfers.Invoke($view, [object[]] @([string] $targetDirectory))).Count -eq 0) 'Transfer actions appeared without a prepared transfer.'
        $emptyContent = $menuType.GetMethod('GetContentMenuForContext', $factoryFlags).Invoke($null, [object[]] @([string[]] @($clipboardDestination), $ownerHandle, $snapshot, $true, $null, $null))
        try { Assert-True ('paste' -notin @(Get-ShellMenuVerbs $emptyContent)) 'Native background paste appeared without supported clipboard data.' }
        finally { ([IDisposable] $emptyContent).Dispose() }
        $cutData = [System.Windows.DataObject]::new()
        $cutPaths = [System.Collections.Specialized.StringCollection]::new()
        $null = $cutPaths.Add($menuClipboardFile)
        $cutData.SetFileDropList($cutPaths)
        $cutData.SetData('Preferred DropEffect', [IO.MemoryStream]::new([BitConverter]::GetBytes([uint32] 2)))
        [System.Windows.Clipboard]::SetDataObject($cutData, $true)
        Assert-True (@($createTransfers.Invoke($view, [object[]] @([string] $targetDirectory))).Count -eq 0) 'Clipboard Cut appeared as a Copy paste action.'
        [System.Windows.Clipboard]::SetText('no clipboard files')
        foreach ($operation in @('Link', 'Copy', 'Move')) {
            foreach ($background in @($false, $true)) {
                $sourceFile = Join-Path $directory ("content-$operation-$background.txt")
                [IO.File]::WriteAllText($sourceFile, 'content transfer')
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $workflow.Prepare([string[]] @($sourceFile))
                $destination = if ($background) { $clipboardDestination } else { $targetDirectory }
                $target = $null
                if (-not $background) {
                    $null = $view.GetType().GetMethod('RevealInsertedItems', $viewFlags).Invoke($view, [object[]] @(,[string[]] @($targetDirectory)))
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
                    $targetRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq $targetDirectory })[0]
                    Assert-True ($probe.Ready -and $null -ne $targetRow) 'Transfer destination row did not reload.'
                    $target = $targetRow.PSObject.BaseObject
                    $list.SelectedItem = $target
                    Assert-True ($list.SelectedItems.Count -eq 1) 'Transfer destination was not selected.'
                }
                $null = $controllerReset.Invoke($controller, @())
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try { $null = $controllerShow.Invoke($controller, [object[]] @($target, $ownerHandle, $true)) }
                finally { $menuProbe.Dispose() }
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectLabel = switch ($operation) {
                    'Link' { 'Insert link to marked item' }
                    'Copy' { 'Insert copy of marked item' }
                    'Move' { 'Move marked item here' }
                }
                try {
                    $null = $controllerShow.Invoke($controller, [object[]] @($target, $ownerHandle, $true))
                    Assert-True ($menuProbe.Items[0] -ceq 'Abort transfer' -and $menuProbe.Items[1] -ceq $menuProbe.SelectLabel -and
                        ($menuProbe.States[2] -band 0x800) -ne 0 -and $menuProbe.SelectIndex -eq 1) "Incorrect $operation content menu for background=$background."
                } finally { $menuProbe.Dispose() }
                $name = [IO.Path]::GetFileName($sourceFile)
                if ($operation -eq 'Link') { $name += ' - Shortcut.lnk' }
                Assert-True ([IO.File]::Exists((Join-Path $destination $name)) -and -not $workflow.IsPrepared -and
                    ([IO.File]::Exists($sourceFile) -eq ($operation -ne 'Move'))) "$operation used the wrong content-menu destination or did not complete."
            }
        }
        $abortSource = Join-Path $directory 'abort-content.txt'
        [IO.File]::WriteAllText($abortSource, 'abort')
        $null = $view.GetType().GetMethod('RevealInsertedItems', $viewFlags).Invoke($view, [object[]] @(,[string[]] @($targetDirectory)))
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
        Assert-True $probe.Ready 'Content view did not settle before testing abort.'
        $workflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $workflow.Prepare([string[]] @($abortSource))
        $null = $controllerReset.Invoke($controller, @())
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try { $null = $controllerShow.Invoke($controller, [object[]] @($null, $ownerHandle, $true)) }
        finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectLabel = 'Abort transfer'
        try {
            $null = $controllerShow.Invoke($controller, [object[]] @($null, $ownerHandle, $true))
            Assert-True ($menuProbe.SelectIndex -eq 0 -and -not $workflow.IsPrepared -and [IO.File]::Exists($abortSource)) 'Content menu abort did not clear the prepared transfer.'
        } finally { $menuProbe.Dispose() }
        $notesPath = Join-Path $clipboardDestination 'notes.txt'
        $null = $view.GetType().GetMethod('RevealInsertedItems', $viewFlags).Invoke($view, [object[]] @(,[string[]] @($notesPath)))
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
        $fileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq $notesPath })[0]
        Assert-True ($probe.Ready -and $null -ne $fileRow) 'File context-menu fixture did not load.'
        $workflow.Prepare([string[]] @($abortSource))
        $list.SelectedItem = $fileRow.PSObject.BaseObject
        $null = $controllerReset.Invoke($controller, @())
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try { $null = $controllerShow.Invoke($controller, [object[]] @($fileRow.PSObject.BaseObject, $ownerHandle, $true)) }
        finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $controllerShow.Invoke($controller, [object[]] @($fileRow.PSObject.BaseObject, $ownerHandle, $true))
            Assert-True ('Abort transfer' -notin $menuProbe.Items -and 'Insert copy of marked item' -notin $menuProbe.Items -and $workflow.IsPrepared) 'File content menu unexpectedly offered directory transfer actions.'
        } finally { $menuProbe.Dispose(); $workflow.Abort() }
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