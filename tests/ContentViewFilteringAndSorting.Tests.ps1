. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$sortStateType = $assembly.GetType('SUTWinExplorer.DirectorySortState', $true)
$pairsProperty = $sortStateType.GetProperty('Pairs', $viewFlags)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-content-sorting-test-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'notes')
    [System.IO.File]::WriteAllText((Join-Path $directory 'other.txt'), 'other')
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $view.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $true
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
        Assert-True ($probe.Ready -and $list.Items.Count -eq 2) "ContentView sorting fixture did not load: ready=$($probe.Ready), count=$($list.Items.Count), error=$($probe.Error)"
        $nameColumn = $view.FindName('NameColumn')
        $sizeColumn = $view.FindName('SizeColumn')
        $modifierColumn = $view.FindName('ModifierIconColumn')
        $list.SelectedItems.Add($list.Items[0]) | Out-Null
        $list.SelectedItems.Add($list.Items[$list.Items.Count - 1]) | Out-Null
        $selectedPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        $sizeColumn.Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($view.FindName('SizeSortIndicator').Visibility -eq 'Visible' -and
            $view.FindName('SizeSortIndicator').Text -ceq [string] [char] 0x25B2) 'Ascending size indicator was not shown.'
        $sizeColumn.Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($view.FindName('SizeSortIndicator').Text -ceq [string] [char] 0x25BC) 'Descending size indicator was not shown.'
        $nameColumn.Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $list.UpdateLayout()
        Assert-True ($view.FindName('NameSortIndicator').Visibility -eq 'Visible' -and
            $view.FindName('SizeSortIndicator').Visibility -eq 'Collapsed' -and
            $view.FindName('NameSortIndicator').IsVisible -and $view.FindName('NameSortIndicator').ActualWidth -gt 0 -and
            $view.FindName('NameSortIndicator').Text -ceq [string] [char] 0x25B2) 'Primary sort indicator did not move to the new column.'
        $viewSort = $view.GetType().GetField('_sorting', $viewFlags).GetValue($view)
        Assert-True ((@($pairsProperty.GetValue($viewSort)).Column -join ',') -ceq 'Name,Size,MediaTypeIcon,TypeApp1Icon,TypeApp2Name,DateModified') 'Column clicks did not preserve the secondary sort.'
        $modifierColumn.Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ((@($pairsProperty.GetValue($viewSort)).Column -join ',') -ceq 'Name,Size,MediaTypeIcon,TypeApp1Icon,TypeApp2Name,DateModified') 'MO header must not change the sorting.'
        foreach ($iconColumn in @(@('MediaTypeIcon', 'MediaTypeIconSortIndicator'), @('TypeApp1Icon', 'TypeApp1IconSortIndicator'))) {
            $header = $view.FindName($iconColumn[0]).Header
            foreach ($direction in @([char] 0x25B2, [char] 0x25BC)) {
                $header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                $list.UpdateLayout()
                $indicator = $view.FindName($iconColumn[1])
                $indicatorPosition = $indicator.TranslatePoint([System.Windows.Point]::new(0, 0), $header)
                $label = $header.Content.Children[0]
                Assert-True ($indicator.IsVisible -and $indicator.Text -ceq [string] $direction -and
                    $indicator.ActualWidth + $indicator.Margin.Left + $indicator.Margin.Right -ge $indicator.DesiredSize.Width -and
                    $label.ActualWidth -ge $label.DesiredSize.Width -and
                    $indicatorPosition.X + $indicator.ActualWidth -le $header.ActualWidth) "Icon header $($iconColumn[0]) did not fit: direction=$direction, text=$($indicator.Text), label=$($label.ActualWidth)/$($label.DesiredSize.Width), indicator=$($indicator.ActualWidth)/$($indicator.DesiredSize.Width), right=$($indicatorPosition.X + $indicator.ActualWidth), header=$($header.ActualWidth)."
            }
            $header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $nameColumn.Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $view.FindName('NamePatternTextBox').Text = '*'
        $view.FindName('NamePatternTextBox').Text = ''
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
        $restoredPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($probe.Ready -and $restoredPaths.Count -eq 2 -and
            @($selectedPaths | Where-Object { $_ -notin $restoredPaths }).Count -eq 0) 'Sorting did not preserve selected paths.'
        $otherView = [Activator]::CreateInstance($view.GetType())
        $otherSort = $otherView.GetType().GetField('_sorting', $viewFlags).GetValue($otherView)
        Assert-True ((@($pairsProperty.GetValue($otherSort)).Column -join ',') -ceq 'Name,MediaTypeIcon,TypeApp1Icon,TypeApp2Name,DateModified,Size' -and
            @($pairsProperty.GetValue($otherSort) | Where-Object { $_.Criterion -ne 'Ascending' }).Count -eq 0) 'Sort history leaked into another ContentView.'
        $view.FindName('NamePatternTextBox').Text = 'notes*.txt'
        Wait-ListCount $list 1
        Assert-True ($list.Items[0].Entry.FullPath -eq (Join-Path $directory 'notes.txt')) 'The name filter did not select the matching file.'
        $view.FindName('NamePatternTextBox').Text = ''
        Wait-ListCount $list 2
    } finally { $window.Close() }
    'ContentView filtering and sorting tests passed.'
} finally {
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}