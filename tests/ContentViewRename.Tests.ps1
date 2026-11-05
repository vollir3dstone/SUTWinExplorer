. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-rename-actions-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current

try {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'notes')
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
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
        Assert-True ($probe.Ready -and $list.Items.Count -eq 1) "Rename action fixture did not load: $($probe.Error)"
        $notesRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $list.SelectedItem = $notesRow
        Assert-True $view.FindName('RenameButton').IsEnabled 'Rename must be enabled for one loaded item.'
        $list.ScrollIntoView($notesRow)
        $list.UpdateLayout()
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::F2)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $list.RaiseEvent($keyEvent)
        $list.UpdateLayout()
        $editor = Find-VisualName $list.ItemContainerGenerator.ContainerFromItem($notesRow) 'ItemNameEditor'
        Assert-True ($null -ne $editor -and $editor.IsVisible -and $editor.Text -eq 'notes.txt') 'The inline rename editor was not rendered.'
        Assert-True ($notesRow.IsEditing -and $notesRow.EditName -eq 'notes.txt') 'Inline rename did not start with the actual file name.'
        $editor.Text = 'cancelled.txt'
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        Assert-True ([object]::ReferenceEquals($list.ItemsSource[0], $list.Items[0]) -and $notesRow.IsEditing) 'Refresh interrupted an active rename.'
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Escape)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $editor.RaiseEvent($keyEvent)
        Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'notes.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $directory 'cancelled.txt'))) 'Cancel changed the file.'
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
        Assert-True ($probe.Ready -and $list.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'notes.txt')) 'Deferred refresh did not retain the selected file.'
        $view.FindName('RenameButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $list.UpdateLayout()
        $editor = Find-VisualName $list.ItemContainerGenerator.ContainerFromItem($list.SelectedItem) 'ItemNameEditor'
        Assert-True ($null -ne $editor -and $editor.IsVisible) 'The inline editor did not reopen.'
        $editor.Text = 'renamed-notes.txt'
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Enter)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $editor.RaiseEvent($keyEvent)
        Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'renamed-notes.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $directory 'notes.txt'))) 'Inline rename did not rename the file correctly.'
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
        Assert-True ($probe.Ready -and $list.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt')) 'Renamed file was not reselected.'
    } finally { $window.Close() }
    'ContentView rename interaction tests passed.'
} finally {
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}