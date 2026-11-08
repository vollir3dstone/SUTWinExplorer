. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$viewFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$newItemTypes = $assembly.GetType('SUTWinExplorer.NewItemOperations', $true).GetMethod('GetTypes', $flags).Invoke($null, @())
if ($newItemTypes[0].Kind.ToString() -cne 'Directory') { throw 'The New dialog directory type is missing.' }
function Wait-Selection($view, [string[]] $expected) {
    $list = $view.FindName('FileList')
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $state = @{ Ready = $false }
    $timer.add_Tick({
        $paths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        if ($paths.Count -eq $expected.Count -and @($expected | Where-Object { $_ -notin $paths }).Count -eq 0) {
            $state.Ready = $true
            $frame.Continue = $false
        } elseif ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $state.Ready) {
        $status = $view.FindName('StatusLabel')
        throw "Inserted items were not selected: expected $expected, actual $($list.SelectedItems | ForEach-Object { $_.Entry.FullPath }), rows=$($list.Items.Count), status=$($status.Text) $($status.ToolTip), existing=$(@($expected | Where-Object { Test-Path -LiteralPath $_ }).Count)."
    }
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutInsertedItems-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $directory 'source'
$destination = Join-Path $directory 'destination'
[IO.Directory]::CreateDirectory($source) | Out-Null
[IO.Directory]::CreateDirectory($destination) | Out-Null
try {
    $first = Join-Path $source 'first.txt'
    $second = Join-Path $source 'second.txt'
    [IO.File]::WriteAllText($first, 'first')
    [IO.File]::WriteAllText($second, 'second')
    [System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
    $application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
    $application.InitializeComponent()
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $view.EnableInternalItemTransfers = $true
    $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $false))
    $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] ($destination + [IO.Path]::DirectorySeparatorChar)))
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Width = 1000
    $window.Height = 500
    $window.Content = $view
    try {
        $window.Show()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $hideDirectories = $view.FindName('HideDirectoriesCheckBox').GetCheckBox()
        $hideInternal = $view.FindName('HideInternalContentCheckBox').GetCheckBox()
        $pattern = $view.FindName('NamePatternTextBox')
        $hiddenFile = Join-Path $source '.inserted.txt'
        $newFolder = Join-Path $source 'inserted-folder'
        [IO.File]::WriteAllText($hiddenFile, 'hidden')
        [IO.Directory]::CreateDirectory($newFolder) | Out-Null
        $hideDirectories.IsChecked = $true
        $hideInternal.IsChecked = $true
        $pattern.Text = 'unrelated*'
        $copyWorkflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $copyWorkflow.Prepare([string[]] @($hiddenFile, $newFolder))
        if (-not $view.FindName('ExecuteInternalCopyingButton').IsEnabled) { throw 'Copy execute did not become enabled.' }
        $view.FindName('ExecuteInternalCopyingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $copyTargets = [string[]] @((Join-Path $destination '.inserted.txt'), (Join-Path $destination 'inserted-folder'))
        Wait-Selection $view $copyTargets
        if ($hideDirectories.IsChecked -or $hideInternal.IsChecked -or $pattern.Text -ne '') {
            throw 'Copy did not clear the filters hiding its inserted items.'
        }

        $linkWorkflow = $assembly.GetType('SUTWinExplorer.LinkWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $pattern.Text = 'unrelated*'
        $linkWorkflow.Prepare([string[]] @($first, $second))
        if (-not $view.FindName('ExecuteInternalLinkingButton').IsEnabled -or $view.FindName('PrepareInternalCopyingButton').IsEnabled -or
            $view.FindName('PrepareInternalMovingButton').IsEnabled) { throw 'Prepared Link did not update the transfer buttons.' }
        $view.FindName('ExecuteInternalLinkingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $linkTargets = [string[]] @((Join-Path $destination 'first.txt - Shortcut.lnk'), (Join-Path $destination 'second.txt - Shortcut.lnk'))
        Wait-Selection $view $linkTargets
        if ($linkWorkflow.IsPrepared -or $pattern.Text -ne '' -or -not [IO.File]::Exists($first) -or -not [IO.File]::Exists($second)) {
            throw 'Link execute did not complete, retain its sources, and clear the blocking name filter.'
        }

        foreach ($index in 1..80) { [IO.File]::WriteAllText((Join-Path $destination ('earlier-{0:D3}.txt' -f $index)), 'row') }
        $moveFile = Join-Path $source 'zzzz-visible-move.txt'
        [IO.File]::WriteAllText($moveFile, 'move')
        $hideDirectories.IsChecked = $true
        $hideInternal.IsChecked = $true
        $pattern.Text = '*.txt'
        $moveWorkflow = $assembly.GetType('SUTWinExplorer.MoveWorkflowState', $true).GetProperty('Shared').GetValue($null)
        $moveWorkflow.Prepare([string[]] @($moveFile))
        $view.FindName('ExecuteInternalMovingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Wait-Selection $view ([string[]] @((Join-Path $destination 'zzzz-visible-move.txt')))
        if (-not $hideDirectories.IsChecked -or -not $hideInternal.IsChecked -or $pattern.Text -ne '*.txt') {
            throw 'Move cleared filters that do not hide the inserted item.'
        }
        $window.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $list = $view.FindName('FileList')
        $container = $list.ItemContainerGenerator.ContainerFromItem($list.SelectedItem)
        if ($null -eq $container -or -not $container.IsVisible) { throw 'The inserted item was not brought into view.' }
        $offset = $container.TranslatePoint([System.Windows.Point]::new(0, 0), $list).Y
        if ($offset -lt 0 -or $offset + $container.ActualHeight -gt $list.ActualHeight) {
            throw "The inserted item is outside the visible list: offset=$offset."
        }

        $pathview = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true),
            [object[]] @([string] $destination, [bool] $false, $null, $null, $null, $null))
        $pathview.EnableInternalItemTransfers = $true
        $window.Content = $pathview
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $directoryContent = $pathview.FindName('DirectoryContent')
        $menuActionOrder = @($directoryContent.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($directoryContent, @()) | ForEach-Object { $_.Id })
        $sidebarController = $pathview.GetType().GetField('_subdirectoryContextMenu', $viewFlags).GetValue($pathview)
        $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        function Invoke-PathviewBackgroundTransfer([string] $operation) {
            $button = $directoryContent.FindName("${operation}ExecuteButton")
            if (-not $button.IsEnabled) { throw "Pathview toolbar $operation execute was not available." }
            $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $directoryContent.FindName('NamePatternTextBox').Text = 'unrelated*'
        $menuCopy = Join-Path $source 'menu-copy.txt'
        [IO.File]::WriteAllText($menuCopy, 'menu')
        $copyWorkflow.Prepare([string[]] @($menuCopy))
        Invoke-PathviewBackgroundTransfer 'Copy'
        Wait-Selection $directoryContent ([string[]] @((Join-Path $destination 'menu-copy.txt')))
        if ($directoryContent.FindName('NamePatternTextBox').Text -ne '') { throw 'Directory menu copy did not clear the blocking name filter.' }

        $menuMove = Join-Path $source 'menu-move.txt'
        [IO.File]::WriteAllText($menuMove, 'menu move')
        $moveWorkflow.Prepare([string[]] @($menuMove))
        Invoke-PathviewBackgroundTransfer 'Move'
        Wait-Selection $directoryContent ([string[]] @((Join-Path $destination 'menu-move.txt')))
        $menuLink = Join-Path $source 'menu-link.txt'
        [IO.File]::WriteAllText($menuLink, 'menu link')
        $directoryContent.FindName('NamePatternTextBox').Text = 'unrelated*'
        $linkWorkflow.Prepare([string[]] @($menuLink))
        Invoke-PathviewBackgroundTransfer 'Link'
        Wait-Selection $directoryContent ([string[]] @((Join-Path $destination 'menu-link.txt - Shortcut.lnk')))
        if ($linkWorkflow.IsPrepared -or $directoryContent.FindName('NamePatternTextBox').Text -ne '' -or -not [IO.File]::Exists($menuLink)) {
            throw 'Directory menu Link execute did not complete and reveal its shortcut.'
        }
        $sourceView = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
        $sourceView.EnableInternalItemTransfers = $true
        $null = $sourceView.GetType().GetMethod('Initialize', $viewFlags).Invoke($sourceView, [object[]] @([bool] $false))
        $null = $sourceView.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($sourceView, [object[]] @([string] $source))
        $sourceWindow = [System.Windows.Window]::new()
        $sourceWindow.ShowInTaskbar = $false
        $sourceWindow.Left = -20000
        $sourceWindow.Top = -20000
        $sourceWindow.Content = $sourceView
        try {
            $sourceWindow.Show()
            $crossTabFile = Join-Path $source 'cross-tab.txt'
            [IO.File]::WriteAllText($crossTabFile, 'cross tab')
            $null = $sourceView.GetType().GetMethod('RevealInsertedItems', $viewFlags).Invoke($sourceView, [object[]] @(,[string[]] @($crossTabFile)))
            Wait-Selection $sourceView ([string[]] @($crossTabFile))
            $sourceView.FindName('PrepareInternalLinkingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            if (-not $linkWorkflow.IsPrepared -or -not $directoryContent.FindName('ExecuteInternalLinkingButton').IsEnabled -or
                $directoryContent.FindName('PrepareInternalCopyingButton').IsEnabled) { throw 'Prepared Link was not shared across ContentViews.' }
            $directoryContent.FindName('ExecuteInternalLinkingButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Wait-Selection $directoryContent ([string[]] @((Join-Path $destination 'cross-tab.txt - Shortcut.lnk')))
            if ($linkWorkflow.IsPrepared -or $sourceView.FindName('ExecuteInternalLinkingButton').IsEnabled -or -not [IO.File]::Exists($crossTabFile)) {
                throw 'Cross-view Link execute did not reset the shared state and retain the source.'
            }
        } finally { $sourceWindow.Close() }
    } finally {
        if ($null -ne $pathview) { $pathview.GetType().GetMethod('Close', $viewFlags).Invoke($pathview, @()) }
        $window.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
} finally {
    foreach ($operation in @('Link', 'Copy', 'Move')) {
        $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null).Abort()
    }
    if ($null -ne $application) { $application.Shutdown() }
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}
Write-Host 'Inserted item transfer, filter and selection tests passed.'