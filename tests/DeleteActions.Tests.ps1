. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-delete-actions-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current

try {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $view.EnableInternalItemTransfers = $true
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $view.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
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
        $list = $view.FindName('FileList')
        $ownerHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $showMenu = $view.GetType().GetMethod('ShowMenu', $viewFlags)
        Assert-True ((Get-ActionCommandId 'Delete') -ge 0x8000) 'The Delete menu action was not found.'
        $deleteDirectory = Join-Path $directory 'delete-fixture'
        $deleteNames = @('delete-first', 'delete-second', 'delete-folder')
        [System.IO.Directory]::CreateDirectory((Join-Path $deleteDirectory $deleteNames[2])) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $deleteDirectory $deleteNames[0]), 'first')
        [System.IO.File]::WriteAllText((Join-Path $deleteDirectory $deleteNames[1]), 'second')
        [System.IO.File]::WriteAllText((Join-Path $deleteDirectory $deleteNames[2] 'nested'), 'folder content')
        $recycleBin = (New-Object -ComObject Shell.Application).NameSpace(10)
        try {
            $deleteApi = $shell.GetMethod('Delete', $flags)
            $fileOperations = $assembly.GetType('SUTWinExplorer.ShellFileOperations', $true)
            $canDelete = $fileOperations.GetMethod('CanDelete', $flags)
            $driveRoot = [System.IO.Path]::GetPathRoot($deleteDirectory)
            foreach ($invalidPath in @($driveRoot, '\\server\share\', 'relative-file')) {
                Assert-True (-not $canDelete.Invoke($null, [object[]] @([string] $invalidPath))) "A non-deletable path was accepted: $invalidPath"
            }
            foreach ($invalidSelection in @(
                [string[]] @(),
                [string[]] @((Join-Path $deleteDirectory $deleteNames[0]), (Join-Path $deleteDirectory 'missing')),
                [string[]] @((Join-Path $deleteDirectory $deleteNames[0]), $driveRoot)
            )) {
                $failed = $false
                try { $null = $deleteApi.Invoke($null, [object[]] @([string[]] $invalidSelection, [IntPtr]::Zero)) }
                catch { $failed = $_.Exception.InnerException -is [InvalidOperationException] }
                Assert-True ($failed -and [System.IO.File]::Exists((Join-Path $deleteDirectory $deleteNames[0]))) 'An invalid delete selection was accepted or partially deleted.'
            }
            $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $deleteDirectory))
            $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
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
            Assert-True ($probe.Ready -and -not $view.FindName('DeleteButton').IsEnabled) 'Delete was enabled without a selection or the test directory did not load.'
            $firstDeleteRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $deleteDirectory $deleteNames[0]) })[0]
            $secondDeleteRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $deleteDirectory $deleteNames[1]) })[0]
            $list.SelectedItems.Add($firstDeleteRow) | Out-Null
            $list.SelectedItems.Add($secondDeleteRow) | Out-Null
            Assert-True $view.FindName('DeleteButton').IsEnabled 'Delete was not enabled for two files.'
            $view.FindName('PrepareInternalCopyingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True (-not $view.FindName('DeleteButton').IsEnabled) 'Delete was enabled during a prepared Copy.'
            $view.FindName('CopyAbortButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectCommandId = Get-ActionCommandId 'Delete'
            $confirmationProbe = [SutShellDeleteConfirmProbe]::new()
            try {
                $null = $showMenu.Invoke($view, [object[]] @($firstDeleteRow.PSObject.BaseObject))
                Assert-True (($menuProbe.States[(Get-MenuActionIndex $menuProbe 'Delete')] -band 3) -eq 0) 'Delete was disabled in the Base file menu.'
            } finally { $menuProbe.Dispose(); $confirmationProbe.Dispose() }
            Assert-True (-not [System.IO.File]::Exists((Join-Path $deleteDirectory $deleteNames[0])) -and
                -not [System.IO.File]::Exists((Join-Path $deleteDirectory $deleteNames[1]))) 'The Base Menu Delete command did not delete both selected files.'
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
            Assert-True ($probe.Ready -and $list.Items.Count -eq 1) 'The view did not refresh after deleting files.'
            $folderDeleteRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $deleteDirectory $deleteNames[2]) })[0]
            $list.SelectedItem = $folderDeleteRow
            Assert-True $view.FindName('DeleteButton').IsEnabled 'Delete was not enabled for a folder.'
            $confirmationProbe = [SutShellDeleteConfirmProbe]::new()
            try {
                $view.FindName('DeleteButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            } finally { $confirmationProbe.Dispose() }
            Assert-True (-not [System.IO.Directory]::Exists((Join-Path $deleteDirectory $deleteNames[2]))) 'The toolbar Delete command did not delete the folder.'
            $recycled = @($recycleBin.Items() | Where-Object {
                $_.Name -in $deleteNames -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $deleteDirectory, [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-True ($recycled.Count -eq 3) "The Shell did not put all test objects in the Recycle Bin: $($recycled.Count)."
        } finally {
            foreach ($item in @($recycleBin.Items() | Where-Object {
                $_.Name -in $deleteNames -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $deleteDirectory, [StringComparison]::OrdinalIgnoreCase)
            })) { $item.Verbs().Item(0).DoIt() }
            $remaining = @($recycleBin.Items() | Where-Object {
                $_.Name -in $deleteNames -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $deleteDirectory, [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-True ($remaining.Count -eq 0) "Could not restore $($remaining.Count) Delete test fixtures from the Recycle Bin."
        }
        $backgroundDirectory = Join-Path $directory 'background-delete-fixture'
        [System.IO.Directory]::CreateDirectory($backgroundDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $backgroundDirectory 'selected-file'), 'content')
        try {
            $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $backgroundDirectory))
            $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
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
            Assert-True ($probe.Ready -and $list.Items.Count -eq 1) 'The background Delete fixture did not load.'
            $list.SelectedItem = $list.Items[0]
            $actions = $view.GetType().GetMethod('CreateActiveDirectoryMenuActions', $viewFlags).Invoke($view, @())
            $deleteAction = @($actions | Where-Object { $_.Id -eq 'Delete' })[0]
            Assert-True $deleteAction.IsEnabled 'Background Delete was disabled for the active directory.'
            $confirmationProbe = [SutShellDeleteConfirmProbe]::new()
            try { $deleteAction.Invoke.Invoke() } finally { $confirmationProbe.Dispose() }
            Assert-True (-not [System.IO.Directory]::Exists($backgroundDirectory)) 'Background Delete did not delete the active directory.'
            $recycled = @($recycleBin.Items() | Where-Object {
                $_.Name -eq 'background-delete-fixture' -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $directory, [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-True ($recycled.Count -eq 1) 'Background Delete did not send the active directory to the Recycle Bin.'
        } finally {
            foreach ($item in @($recycleBin.Items() | Where-Object {
                $_.Name -eq 'background-delete-fixture' -and [string]::Equals($recycleBin.GetDetailsOf($_, 1), $directory, [StringComparison]::OrdinalIgnoreCase)
            })) { $item.Verbs().Item(0).DoIt() }
        }
    } finally { $window.Close() }
    'Delete action tests passed.'
} finally {
    $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null).Abort()
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}