. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-new-actions-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'notes')
    foreach ($index in 1..80) {
        [System.IO.File]::WriteAllText((Join-Path $directory ('visible-test-{0:D3}.txt' -f $index)), 'test')
    }
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $menuActionOrder = @($view.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($view, @()) | ForEach-Object { $_.Id })
    $otherView = [Activator]::CreateInstance($view.GetType())
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
        $dirCount = $view.FindName('DirectoryCountLabel')
        $fileCount = $view.FindName('FileCountLabel')
        $ownerHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
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
        Assert-True ($probe.Ready -and $view.FindName('NewButton').IsEnabled) "New action fixture did not load: $($probe.Error)"
        $hideDirectories = $view.FindName('HideDirectoriesCheckBox').GetCheckBox()
        $otherHideDirectories = $otherView.FindName('HideDirectoriesCheckBox').GetCheckBox()
        Assert-True ($hideDirectories.IsChecked -and $otherHideDirectories.IsChecked) 'The directory filter was not set before the New dialog test.'
        foreach ($mode in @('Cancel', 'CancelFolder', 'Focus', 'Folder', 'Mismatch', 'HiddenText', 'ScrollText')) {
            if ($mode -eq 'Folder' -or $mode -eq 'HiddenText') { $view.FindName('NamePatternTextBox').Text = 'notes*.txt' }
            if ($mode -eq 'HiddenText') { $view.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked = $true }
            $newProbe = Start-NewDialogProbe $mode
            try {
                $view.FindName('NewButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                Assert-True ($newProbe.Seen -and $null -eq $newProbe.Error) "The New button did not complete the $mode dialog: $($newProbe.Error)."
                if ($mode -eq 'Cancel') { Assert-True ($newProbe.ListCorrect -and -not (Test-Path -LiteralPath (Join-Path $directory 'chosen-folder'))) "The type list, icons, scrolling or cancel state was incorrect: $($newProbe.ListDetails)." }
                if ($mode -eq 'CancelFolder' -or $mode -eq 'Focus') { Assert-True $hideDirectories.IsChecked 'Choosing Folder before cancelling changed the directory filter.' }
                if ($mode -eq 'Focus') { Assert-True $newProbe.FocusCorrect 'Clicking a type, including the selected type, did not focus the name editor.' }
                if ($mode -eq 'Folder') { Assert-True ([IO.Directory]::Exists((Join-Path $directory 'chosen-folder')) -and -not $hideDirectories.IsChecked -and $otherHideDirectories.IsChecked -and $view.FindName('NamePatternTextBox').Text -eq '') 'Creating Folder did not update only the necessary local filters.' }
                if ($mode -eq 'Mismatch') { Assert-True ($newProbe.ExtensionChanged -and $newProbe.MismatchRejected -and [IO.File]::Exists((Join-Path $directory 'chosen-name.txt'))) 'Extension changes, mismatch confirmation or named text creation failed.' }
                if ($mode -eq 'HiddenText') { Assert-True (-not $view.FindName('HideInternalContentCheckBox').GetCheckBox().IsChecked -and $view.FindName('NamePatternTextBox').Text -eq '') 'Creating an internal item did not clear the filters hiding it.' }
                if ($mode -in @('Folder', 'Mismatch', 'HiddenText', 'ScrollText')) {
                    $createdName = switch ($mode) { 'Folder' { 'chosen-folder' } 'Mismatch' { 'chosen-name.txt' } 'HiddenText' { '.chosen-hidden.txt' } 'ScrollText' { 'zzzz-last.txt' } }
                    foreach ($refresh in @($false, $true)) {
                        if ($refresh) { $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true)) }
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
                        $selected = $list.SelectedItem
                        $container = if ($null -ne $selected) { $list.ItemContainerGenerator.ContainerFromItem($selected) } else { $null }
                        Assert-True ($probe.Ready -and $list.SelectedItems.Count -eq 1 -and $selected.Entry.FullPath -eq (Join-Path $directory $createdName) -and
                            $null -ne $selected.Entry -and $null -ne $container -and $container.IsVisible) "The created $mode item was not visible and selected after refresh=$refresh`: ready=$($probe.Ready), error=$($probe.Error), count=$($list.SelectedItems.Count), selected=$($selected.Entry.FullPath), loaded=$($null -ne $selected.Entry), container=$($null -ne $container), visible=$($container.IsVisible)."
                        Assert-True ($dirCount.Text -eq "$(@([IO.Directory]::EnumerateDirectories($directory)).Count)" -and
                            $fileCount.Text -eq "$(@([IO.Directory]::EnumerateFiles($directory)).Count)") 'The unfiltered counts did not update after creating an item.'
                        if ($mode -eq 'ScrollText') {
                            $scroll = Find-VisualType $list ([System.Windows.Controls.ScrollViewer])
                            $position = $container.TranslatePoint([System.Windows.Point]::new(0, 0), $scroll)
                            Assert-True ($scroll.VerticalOffset -gt 0 -and $position.Y -ge 0 -and $position.Y + $container.ActualHeight -le $scroll.ActualHeight) 'The created item was not scrolled into the visible viewport.'
                        }
                    }
                }
            } finally { $newProbe.Timer.Stop() }
        }
        [IO.Directory]::Delete((Join-Path $directory 'chosen-folder'))
        [IO.File]::Delete((Join-Path $directory 'chosen-name.txt'))
        [IO.File]::Delete((Join-Path $directory '.chosen-hidden.txt'))
        [IO.File]::Delete((Join-Path $directory 'zzzz-last.txt'))
        $hideDirectories.IsChecked = $true
        $newProbe = Start-NewDialogProbe 'Windows'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $view.FindName('NewButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ($newProbe.Seen -and $null -eq $newProbe.Error -and $menuProbe.ItemCount -gt 1) 'The explicit Windows fallback did not open the native New submenu.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
        $list.SelectedItems.Clear()
        $showMenuCore = $view.GetType().GetMethod('ShowMenuCore', $viewFlags)
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($null, $true))
            Assert-True (Test-BaseMenu $menuProbe) 'The background Base Menu was not shown before the New action.'
        } finally { $menuProbe.Dispose() }
        $newProbe = Start-NewDialogProbe 'Cancel'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'New' @('New')
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($null, $true))
            Assert-True ($menuProbe.SelectIndex -ge 0 -and $newProbe.Seen -and $null -eq $newProbe.Error) 'The ContentView background New action did not open the shared dialog.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
    } finally { $window.Close() }
    'New item action tests passed.'
} finally {
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}