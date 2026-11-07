. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$testView = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
$menuActionOrder = @($testView.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($testView, @()) | ForEach-Object { $_.Id })
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-pathview-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'OtherFolder')) | Out-Null
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $pathviewType = $assembly.GetType('SUTWinExplorer.Pathview', $true)
    $fixedPathview = $pathviewType.GetConstructors()[0].Invoke([object[]] @([string] $directory, [bool] $false, $null, $null, $null, $null))
    $fixedWindow = [System.Windows.Window]::new()
    try {
        $fixedWindow.ShowInTaskbar = $false
        $fixedWindow.Left = -20000
        $fixedWindow.Top = -20000
        $fixedWindow.Width = 800
        $fixedWindow.Height = 650
        $fixedWindow.Content = $fixedPathview
        $fixedWindow.Show()
        $fixedWindow.UpdateLayout()
        foreach ($action in @(@{ Button = 'RenameCurrentDirectoryButton'; Title = 'Rename directory'; Value = [IO.Path]::GetFileName($directory) },
                              @{ Button = 'RelocateCurrentDirectoryButton'; Title = 'Relocate directory'; Value = [IO.Path]::GetDirectoryName($directory) })) {
            $button = $fixedPathview.FindName($action.Button)
            Assert-True $button.IsEnabled "$($action.Button) was disabled for the current directory."
            $state = @{ Seen = $false; Value = $null }
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick({
                $dialog = @([System.Windows.Application]::Current.Windows | Where-Object { $_.Title -eq $action.Title -and $_.IsVisible }) | Select-Object -First 1
                if ($null -ne $dialog) {
                    $state.Seen = $true
                    $state.Value = $dialog.Content.Children[1].Text
                    $dialog.DialogResult = $false
                }
            }.GetNewClosure())
            $timer.Start()
            try { $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
            finally { $timer.Stop() }
            Assert-True ($state.Seen -and $state.Value -ceq $action.Value -and $fixedPathview.CurrentPath -ceq $directory) "$($action.Button) did not open the expected dialog for the current path."
        }
        $subdirectoryList = $fixedPathview.FindName('ActivePathSubdirectoriesList')
        $subdirectoryEntry = @($subdirectoryList.Items | Where-Object { $_.Path -eq (Join-Path $directory 'OtherFolder') })[0]
        Assert-True ($null -ne $subdirectoryEntry) 'The fixed Pathview fixture did not find its subdirectory.'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $sidebarController = $pathviewType.GetField('_subdirectoryContextMenu', $viewFlags).GetValue($fixedPathview)
        $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle
        $sidebarContent = $fixedPathview.FindName('DirectoryContent')
        $sidebarHideDirectories = $sidebarContent.FindName('HideDirectoriesCheckBox').GetCheckBox()
        $sidebarHideDirectories.IsChecked = $true
        $null = $sidebarController.GetType().GetMethod('Reset', $viewFlags).Invoke($sidebarController, @())
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        try { $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true)) }
        finally { $menuProbe.Dispose() }
        $newProbe = Start-NewDialogProbe 'CancelFolder'
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'New' @('New')
        try {
            $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true))
            Assert-True ($menuProbe.SelectIndex -ge 0 -and $newProbe.Seen -and $null -eq $newProbe.Error -and $sidebarHideDirectories.IsChecked) 'Cancelling the sidebar New dialog changed the directory filter.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
        $null = $sidebarController.GetType().GetMethod('Reset', $viewFlags).Invoke($sidebarController, @())
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        try { $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true)) }
        finally { $menuProbe.Dispose() }
        $newProbe = Start-NewDialogProbe 'Folder'
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'New' @('New')
        try {
            $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true))
            Assert-True ($menuProbe.SelectIndex -ge 0 -and $newProbe.Seen -and $null -eq $newProbe.Error -and -not $sidebarHideDirectories.IsChecked) 'Creating a sidebar folder did not clear the local directory filter.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
        $sidebarList = $sidebarContent.FindName('FileList')
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $sidebarList
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and $sidebarList.SelectedItems.Count -eq 1 -and $sidebarList.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'chosen-folder')) 'The sidebar-created folder was not selected in its ContentView.'
        [IO.Directory]::Delete((Join-Path $directory 'chosen-folder'))
        $sidebarHideDirectories.IsChecked = $true
        foreach ($operation in @('Copy', 'Move')) {
            $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
            $workflow.Prepare([string[]] @($subdirectoryEntry.Path))
            $null = $sidebarController.GetType().GetMethod('Reset', $viewFlags).Invoke($sidebarController, @())
            $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle
            $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
            $menuProbe.SelectCommandId = Get-ActionCommandId 'AbortTransfer'
            try {
                $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true))
                Assert-True (($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[2] -band 3) -ne 0 -and ($menuProbe.States[3] -band 3) -ne 0 -and
                    ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'CopyMarkItem')] -band 3) -ne 0 -and ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'MoveMarkItem')] -band 3) -ne 0 -and ($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0 -and
                    -not $workflow.IsPrepared) "The sidebar background $operation action did not match the workflow state."
            } finally { $menuProbe.Dispose(); $workflow.Abort() }
        }
        $sidebarSource = Join-Path $directory 'sidebar-transfer.txt'
        [IO.File]::WriteAllText($sidebarSource, 'sidebar transfer')
        $workflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $workflow.Prepare([string[]] @($sidebarSource))
        $null = $sidebarController.GetType().GetMethod('Reset', $viewFlags).Invoke($sidebarController, @())
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        try { $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true)) }
        finally { $menuProbe.Dispose() }
        $newProbe = Start-NewDialogProbe 'CancelFolder'
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'New' @('New')
        try {
            $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($null, $sidebarOwner, $true))
            Assert-True ($newProbe.Seen -and $null -eq $newProbe.Error -and $workflow.IsPrepared) 'The New command was displaced by the active transfer actions.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
        $fixedPathview.GetType().GetMethod('SelectDirectoryMenuTarget', $viewFlags).Invoke($fixedPathview, [object[]] @($subdirectoryEntry.PSObject.BaseObject, $false))
        $null = $sidebarController.GetType().GetMethod('Reset', $viewFlags).Invoke($sidebarController, @())
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        try { $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($subdirectoryEntry.PSObject.BaseObject, $sidebarOwner, $true)) }
        finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
        $menuProbe.SelectLabel = 'Insert copy of marked item'
        try {
            $null = $sidebarController.GetType().GetMethod('Show', $viewFlags).Invoke($sidebarController, [object[]] @($subdirectoryEntry.PSObject.BaseObject, $sidebarOwner, $true))
            Assert-True ($menuProbe.SelectIndex -eq 1 -and $menuProbe.Items[0] -ceq 'Abort transfer' -and
                [IO.File]::Exists((Join-Path $subdirectoryEntry.Path 'sidebar-transfer.txt')) -and -not $workflow.IsPrepared) 'Sidebar directory content menu copied to the wrong destination.'
        } finally { $menuProbe.Dispose(); $workflow.Abort() }
        $activeTree = $fixedPathview.FindName('ActivePathTree')
        $treeItem = $activeTree.ItemContainerGenerator.ContainerFromIndex(0)
        Assert-True ($null -ne $treeItem) 'The fixed Active path tree was not realized.'
        $menuProbe = [SutShellMenuProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle)
        try {
            $event = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Right)
            $event.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
            $treeItem.RaiseEvent($event)
            Assert-True ($menuProbe.ItemCount -eq -1) 'The fixed Active path tree unexpectedly opened a menu.'
            } finally { $menuProbe.Dispose() }
    } finally { $fixedWindow.Close() }
    $operationPath = Join-Path $directory 'operation'
    $destination = Join-Path $directory 'destination'
    [void] [IO.Directory]::CreateDirectory($operationPath)
    [void] [IO.Directory]::CreateDirectory($destination)
    $operationView = $pathviewType.GetConstructors()[0].Invoke([object[]] @([string] $operationPath, [bool] $false, $null, $null, $null, $null))
    $operationWindow = [System.Windows.Window]::new()
    try {
        $operationWindow.ShowInTaskbar = $false
        $operationWindow.Left = -20000
        $operationWindow.Top = -20000
        $operationWindow.Content = $operationView
        $operationWindow.Show()
        foreach ($action in @(@{ Button = 'RenameCurrentDirectoryButton'; Title = 'Rename directory'; Value = 'renamed'; Expected = (Join-Path $directory 'renamed') },
                              @{ Button = 'RelocateCurrentDirectoryButton'; Title = 'Relocate directory'; Value = $destination; Expected = (Join-Path $destination 'renamed') })) {
            $state = @{ Seen = $false }
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick({
                $dialog = @([System.Windows.Application]::Current.Windows | Where-Object { $_.Title -eq $action.Title -and $_.IsVisible }) | Select-Object -First 1
                if ($null -ne $dialog) {
                    $state.Seen = $true
                    $dialog.Content.Children[1].Text = $action.Value
                    $dialog.DialogResult = $true
                }
            }.GetNewClosure())
            $timer.Start()
            try { $operationView.FindName($action.Button).RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
            finally { $timer.Stop() }
            $activeEntry = $operationView.GetType().GetField('_activePathEntry', $viewFlags).GetValue($operationView)
            Assert-True ($state.Seen -and $operationView.CurrentPath -ceq $action.Expected -and $activeEntry.Path -ceq $action.Expected) "$($action.Button) did not update the visible active path."
        }
    } finally {
        $operationView.GetType().GetMethod('Close', $viewFlags).Invoke($operationView, @())
        $operationWindow.Close()
    }
    'Pathview tests passed.'
} finally {
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}