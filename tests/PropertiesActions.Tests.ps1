. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-properties-actions-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'notes')
    [System.IO.File]::WriteAllText((Join-Path $directory 'other.txt'), 'other')
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
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
        $notesRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $otherRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'other.txt') })[0]
        $folderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'Folder') })[0]
        Assert-True ($probe.Ready -and $null -ne $notesRow -and $null -ne $otherRow -and $null -ne $folderRow) "Properties fixture did not load: $($probe.Error)"
        $list.SelectedItems.Clear()
        Assert-True (-not $view.FindName('PropertiesButton').IsEnabled) 'Properties was enabled without a selection.'
        $list.SelectedItem = $notesRow
        Assert-True $view.FindName('PropertiesButton').IsEnabled 'Properties was disabled for a loaded selected item.'
        $propertiesProbe = [SutShellPropertiesProbe]::new('notes.txt')
        try {
            $view.FindName('PropertiesButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True $propertiesProbe.Opened 'The Properties button did not open the Windows properties dialog for the selected item.'
        } finally { $propertiesProbe.Dispose() }
        $ownerHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $showMenu = $view.GetType().GetMethod('ShowMenu', $viewFlags)
        foreach ($case in @(@{ Row = $notesRow; Title = 'notes.txt'; Multiple = $false },
                            @{ Row = $notesRow; Title = ''; Multiple = $true },
                            @{ Row = $folderRow; Title = 'Folder'; Multiple = $false })) {
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($case.Row) | Out-Null
            if ($case.Multiple) { $list.SelectedItems.Add($otherRow) | Out-Null }
            $propertiesProbe = [SutShellPropertiesProbe]::new($case.Title)
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectCommandId = Get-ActionCommandId 'Properties'
            try {
                $null = $showMenu.Invoke($view, [object[]] @($case.Row.PSObject.BaseObject))
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddSeconds(5)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
                Assert-True ($menuProbe.SelectIndex -eq 0 -and $propertiesProbe.Opened) "Properties did not open from the Base Menu: target=$($case.Title), multiple=$($case.Multiple), index=$($menuProbe.SelectIndex)."
            } finally { $menuProbe.Dispose(); $propertiesProbe.Dispose() }
        }
    } finally { $window.Close() }
    'Properties action tests passed.'
} finally {
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}