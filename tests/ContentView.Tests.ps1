. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$instanceFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$menuType = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
$sortStateType = $assembly.GetType('SUTWinExplorer.DirectorySortState', $true)
$pairsProperty = $sortStateType.GetProperty('Pairs', $instanceFlags)
$testHandler = [guid] '{11111111-2222-3333-4444-555555555555}'
$whitelistJson = '{"_type":"directoryMenuWhitelist","extensions":[{"_type":"shellExtension","name":"test","verbs":["TestVerb"],"clsids":["{11111111-2222-3333-4444-555555555555}"]}]}'
$whitelistDocument = [System.Text.Json.JsonDocument]::Parse($whitelistJson)
try { $parsedWhitelist = $menuType.GetMethod('ParseDirectoryWhitelist', $flags).Invoke($null, @($whitelistDocument)) }
finally { $whitelistDocument.Dispose() }
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-content-test-' + [guid]::NewGuid().ToString('N'))

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'hello')
    [System.IO.File]::SetLastWriteTime((Join-Path $directory 'notes.txt'), [datetime]::new(2026, 11, 2, 9, 5, 0))
    [System.IO.File]::WriteAllText((Join-Path $directory '.internal'), 'hidden')
    [System.IO.File]::WriteAllText((Join-Path $directory 'unknown.zzzunknown'), 'unknown')
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'empty.bin'), [byte[]]::new(0))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'exact.bin'), [byte[]]::new(1024))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'over.bin'), [byte[]]::new(1025))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'large.bin'), [byte[]]::new(1048576))
    $snapshot = $shell.GetMethod('OpenDirectoryAsync', $flags).Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    $entries = @($shell.GetMethod('GetDirectoryRangeAsync', $flags).Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    $notes = @($entries | Where-Object { $_.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
    Assert-True ($null -ne $notes -and $null -ne $notes.Icons.BaseIcon) 'The ContentView fixture did not load the test file and its icon.'
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-b.txt'), 'present')
    [System.IO.File]::WriteAllText((Join-Path $directory 'created.txt'), 'new')
    foreach ($index in 1..80) {
        [System.IO.File]::WriteAllText((Join-Path $directory ('visible-test-{0:D3}.txt' -f $index)), 'test')
    }
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'OtherFolder')) | Out-Null
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $menuActionOrder = @($view.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($view, @()) | ForEach-Object { $_.Id })
    [SutShellRightClickProbe]::PropertiesCommandId = Get-ActionCommandId 'Properties'
    [SutShellRightClickProbe]::NameClipboardCopyCommandId = Get-ActionCommandId 'NameClipboardCopy'
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Width = 800
    $window.Height = 500
    $window.Content = $view
    $window.Show()
    try {
        $defaultOrder = 'Name,MediaTypeIcon,TypeApp1Icon,TypeApp2Name,DateModified,Size'
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $view.FindName('FileList')
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "ContentView did not load and render requested row packages: $($probe.Error)"
        $list = $view.FindName('FileList')
        $newButton = $view.FindName('NewButton')
        $propertiesButton = $view.FindName('PropertiesButton')
        $newPosition = $newButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $propertiesPosition = $propertiesButton.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $listPosition = $list.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $header = $view.FindName('HeaderArea')
        $layout = $header.Parent
        $viewRow = $view.FindName('ViewControlsRow')
        $selectionRow = $view.FindName('SelectionControlsRow')
        $directoryActions = $view.FindName('DirectoryActions')
        $headerPosition = $header.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        Assert-True ($layout.RowDefinitions.Count -eq 2 -and $layout.ColumnDefinitions.Count -eq 2 -and
            @($layout.Children | Where-Object { [System.Windows.Controls.Grid]::GetRow($_) -eq 0 -and [System.Windows.Controls.Grid]::GetColumn($_) -eq 0 }).Count -eq 0 -and
            [System.Windows.Controls.Grid]::GetRow($header) -eq 0 -and [System.Windows.Controls.Grid]::GetColumn($header) -eq 1 -and
            [System.Windows.Controls.Grid]::GetRow($directoryActions) -eq 1 -and [System.Windows.Controls.Grid]::GetColumn($directoryActions) -eq 0 -and
            [System.Windows.Controls.Grid]::GetRow($list) -eq 1 -and [System.Windows.Controls.Grid]::GetColumn($list) -eq 1 -and
            [Math]::Abs($headerPosition.X - $listPosition.X) -lt 1 -and $viewRow.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y -lt
            $selectionRow.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y) "The ContentView grid is incorrect: rows=$($layout.RowDefinitions.Count), columns=$($layout.ColumnDefinitions.Count), header=$([System.Windows.Controls.Grid]::GetRow($header))/$([System.Windows.Controls.Grid]::GetColumn($header)), directory=$([System.Windows.Controls.Grid]::GetRow($directoryActions))/$([System.Windows.Controls.Grid]::GetColumn($directoryActions)), list=$([System.Windows.Controls.Grid]::GetRow($list))/$([System.Windows.Controls.Grid]::GetColumn($list)), x=$($headerPosition.X)/$($listPosition.X), y=$($viewRow.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y)/$($selectionRow.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y)."
        $badge = $view.FindName('DirectoryBadge')
        $badgePosition = $badge.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $heading = $view.FindName('DirectoryHeading')
        $headingPosition = $heading.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
        $dirCount = $view.FindName('DirectoryCountLabel')
        $fileCount = $view.FindName('FileCountLabel')
        $expectedDirs = @([IO.Directory]::EnumerateDirectories($directory)).Count
        $expectedFiles = @([IO.Directory]::EnumerateFiles($directory)).Count
        Assert-True ($dirCount.Text -eq "$expectedDirs" -and $fileCount.Text -eq "$expectedFiles" -and
            $dirCount.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y -ge $badgePosition.Y + $badge.ActualHeight -and
            $fileCount.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y -gt $dirCount.TranslatePoint([System.Windows.Point]::new(0, 0), $view).Y) 'The unfiltered directory and file counts were incorrect or misplaced.'
        Assert-True ($newButton.IsEnabled -and -not $propertiesButton.IsEnabled -and
            $newPosition.X + $newButton.ActualWidth -le $listPosition.X -and $propertiesPosition.Y -lt $listPosition.Y -and
            $badge.Child.Text -eq 'DIRECTORY') 'The directory column, selection row or initial button states were incorrect.'
        foreach ($buttonName in @('NewButton', 'LinkAbortButton', 'LinkExecuteButton', 'CopyAbortButton', 'CopyExecuteButton', 'MoveAbortButton', 'MoveExecuteButton')) {
            $button = $view.FindName($buttonName)
            Assert-True ([Math]::Abs($button.ActualWidth - $badge.ActualWidth) -lt 1) "$buttonName did not match the directory badge width."
        }
        $previousBottom = $headingPosition.Y + $heading.ActualHeight
        $gaps = @()
        $groups = @($directoryActions.Children | Where-Object { [System.Windows.Controls.Grid]::GetRow($_) -gt [System.Windows.Controls.Grid]::GetRow($heading) } | Sort-Object { [System.Windows.Controls.Grid]::GetRow($_) })
        Assert-True ($groups.Count -gt 0) 'The directory action groups are missing.'
        foreach ($group in $groups) {
            $position = $group.TranslatePoint([System.Windows.Point]::new(0, 0), $view)
            $gaps += $position.Y - $previousBottom
            Assert-True ($position.X + $group.ActualWidth -le $listPosition.X -and $position.Y -ge $previousBottom) 'Directory actions were not arranged vertically beside the table.'
            $previousBottom = $position.Y + $group.ActualHeight
        }
        $gaps += $listPosition.Y + $list.ActualHeight - $previousBottom
        Assert-True (($gaps | Measure-Object -Maximum).Maximum - ($gaps | Measure-Object -Minimum).Minimum -lt 1) 'Directory action groups were not evenly spaced.'
        foreach ($buttonName in @('RenameButton', 'NameClipboardCopyButton', 'PathClipboardCopyButton', 'LinkMarkItemButton', 'CopyMarkItemButton', 'MoveMarkItemButton', 'DeleteButton')) {
            $position = $view.FindName($buttonName).TranslatePoint([System.Windows.Point]::new(0, 0), $view)
            Assert-True ([Math]::Abs($position.Y - $propertiesPosition.Y) -lt 1 -and $position.X -gt $propertiesPosition.X) "$buttonName was not after Properties in the selection row."
        }
        $columns = $list.View.Columns
        $nameColumn = $view.FindName('NameColumn')
        $typeColumn = $view.FindName('TypeApp2Name')
        $modifierColumn = $view.FindName('ModifierIconColumn')
        $sizeColumn = $view.FindName('SizeColumn')
        Assert-True ($columns.Count -eq 8 -and $nameColumn.Header.Tag -eq 'Name' -and
            $nameColumn.Width -gt 80 -and $typeColumn.Width -eq 130) 'Shell column order or name-column sizing is incorrect.'
        foreach ($headerCase in @(@('MediaTypeIcon', 'MT'), @('ModifierIconColumn', 'MO'), @('TypeApp1Icon', 'TA1'), @('TypeApp2Name', 'TA2'))) {
            $headerContent = $view.FindName($headerCase[0]).Header.Content
            $headerText = if ($headerContent -is [System.Windows.Controls.TextBlock]) { $headerContent.Text } else { $headerContent.Children[0].Text }
            Assert-True ($headerText -ceq $headerCase[1]) "Column $($headerCase[0]) has an incorrect header."
        }
        $scroll = Find-VisualType $list ([System.Windows.Controls.ScrollViewer])
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        Assert-True (-not $list.View.AllowsColumnReorder -and $scroll.HorizontalScrollBarVisibility -eq 'Disabled' -and
            [Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and $scroll.ScrollableWidth -lt 1) "The columns do not fill the viewport: columns=$widthSum, viewport=$($scroll.ViewportWidth), scrollable=$($scroll.ScrollableWidth)."
        for ($index = 0; $index -lt $columns.Count; $index++) {
            $header = $columns[$index].Header
            $header.ApplyTemplate() | Out-Null
            $gripper = $header.Template.FindName('PART_HeaderGripper', $header)
            Assert-True (([object]::ReferenceEquals($header, $view.FindName('RightColumnsToggleHeader')) -and $null -eq $gripper) -or
                (-not [object]::ReferenceEquals($header, $view.FindName('RightColumnsToggleHeader')) -and $null -ne $gripper -and $gripper.IsEnabled -eq [object]::ReferenceEquals($header, $nameColumn.Header))) "Column $index has an incorrect resize handle."
        }
        $originalNameWidth = $nameColumn.Width
        $originalTypeWidth = $typeColumn.Width
        $nameColumn.Width += 35
        Assert-True ([Math]::Abs($nameColumn.Width - $originalNameWidth - 35) -lt 1 -and
            [Math]::Abs($typeColumn.Width - $originalTypeWidth + 35) -lt 1) 'The Name/Type splitter did not preserve their combined width.'
        $nameColumn.Width = 10000
        Assert-True ($typeColumn.Width -ge 40 -and [Math]::Abs($nameColumn.Width + $typeColumn.Width - $originalNameWidth - $originalTypeWidth) -lt 1) 'The splitter allowed Type to collapse or changed the combined width.'
        $nameColumn.Width = 1
        Assert-True ($nameColumn.Width -ge 80 -and [Math]::Abs($nameColumn.Width + $typeColumn.Width - $originalNameWidth - $originalTypeWidth) -lt 1) 'The splitter allowed Name below its minimum or changed the combined width.'
        $nameColumn.Width = $originalNameWidth
        $window.Width += 100
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        Assert-True ([Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and [Math]::Abs($typeColumn.Width - $originalTypeWidth) -lt 1) 'Window resizing did not preserve the Type width and fill the viewport.'
        $window.Width -= 100
        $window.UpdateLayout()
        $scroll.VerticalScrollBarVisibility = 'Hidden'
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        Assert-True ([Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and $scroll.ScrollableWidth -lt 1) 'The columns did not adapt when the vertical scrollbar disappeared.'
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        Assert-True ([Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and $scroll.ScrollableWidth -lt 1) 'The columns did not adapt when the vertical scrollbar appeared.'
        $originalWindowWidth = $window.Width
        $rightColumnsToggle = $view.FindName('RightColumnsToggleHeader')
        $list.SelectedItem = $list.Items[0]
        $selectedBeforeResize = $list.SelectedItem
        $itemsBeforeResize = $list.ItemsSource
        $thresholdViewport = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum - $nameColumn.Width + 80
        $window.Width = $originalWindowWidth - ($scroll.ViewportWidth - $thresholdViewport) + 2
        $window.UpdateLayout()
        Assert-True ($columns.Count -eq 8 -and $nameColumn.Width -ge 80) 'Right columns disappeared above the minimum Name width.'
        $window.Width -= 4
        $window.UpdateLayout()
        Assert-True ($columns.Count -eq 5) 'Right columns did not disappear below the minimum Name width.'
        $window.Width += 4
        $window.UpdateLayout()
        Assert-True ($columns.Count -eq 8 -and [Math]::Abs($typeColumn.Width - $originalTypeWidth) -lt 1) 'Right columns did not automatically reappear above the minimum Name width.'
        $window.Width = 500
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        Assert-True ($columns.Count -eq 5 -and
            [Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and $scroll.ScrollableWidth -lt 1 -and
            [object]::ReferenceEquals($itemsBeforeResize, $list.ItemsSource) -and [object]::ReferenceEquals($selectedBeforeResize, $list.SelectedItem)) 'The right columns did not hide automatically in a narrow viewport.'
        $rightColumnsToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($columns.Count -eq 8) 'The toggle did not override automatic hiding in a narrow viewport.'
        $rightColumnsToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $window.Width = $originalWindowWidth
        $window.UpdateLayout()
        Assert-True ($columns.Count -eq 5) 'Manually hidden columns reappeared after widening.'
        $rightColumnsToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $window.UpdateLayout()
        Assert-True ($columns.Count -eq 8 -and [Math]::Abs($typeColumn.Width - $originalTypeWidth) -lt 1) 'Columns or the chosen Type width were not restored after widening.'
        $list.SelectedItems.Clear()
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        $originalLeft = $window.Left
        $originalTop = $window.Top
        try {
            $window.Left = 20
            $window.Top = 20
            $null = $window.Activate()
            $window.UpdateLayout()
            $nameHeader = $nameColumn.Header
            $gripper = $nameHeader.Template.FindName('PART_HeaderGripper', $nameHeader)
            $point = $gripper.PointToScreen([System.Windows.Point]::new($gripper.ActualWidth / 2, $gripper.ActualHeight / 2))
            $beforeName = $nameColumn.Width
            $beforeType = $typeColumn.Width
            $drag = [pscustomobject] @{ Phase = 0 }
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(100)
            $timer.add_Tick({
                switch ($drag.Phase) {
                    0 { [SutShellRightClickProbe]::MovePointer([int] $point.X, [int] $point.Y); [SutShellMenuProbe]::LeftDown() }
                    1 { [SutShellRightClickProbe]::MovePointer([int] ($point.X + 10), [int] $point.Y) }
                    2 { [SutShellRightClickProbe]::MovePointer([int] ($point.X + 20), [int] $point.Y) }
                    3 { [SutShellRightClickProbe]::MovePointer([int] ($point.X + 30), [int] $point.Y) }
                    4 { [SutShellMenuProbe]::LeftUp(); $frame.Continue = $false }
                }
                $drag.Phase++
            }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($nameColumn.Width -gt $beforeName + 10 -and $typeColumn.Width -lt $beforeType - 10 -and
                [Math]::Abs(($nameColumn.Width + $typeColumn.Width) - ($beforeName + $beforeType)) -lt 1) 'Dragging the Name/Type divider did not resize both columns together.'
        } finally {
            [SutShellMenuProbe]::LeftUp()
            [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1])
            $window.Left = $originalLeft
            $window.Top = $originalTop
            $nameColumn.Width = $originalNameWidth
        }
        $rightColumnsToggle = $view.FindName('RightColumnsToggleHeader')
        Assert-True ($columns.IndexOf($view.FindName('RightColumnsToggleColumn')) -eq $columns.IndexOf($view.FindName('TypeApp1Icon')) + 1 -and
            $view.FindName('RightColumnsToggleSymbol').Text -ceq [string] [char] 0x25B8) 'The right-column toggle was not positioned after TA1 or initially visible.'
        $list.SelectedItem = $list.Items[0]
        $selectedBeforeToggle = $list.SelectedItem
        $itemsBeforeToggle = $list.ItemsSource
        $rightColumnsToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        $nameGripper = $nameColumn.Header.Template.FindName('PART_HeaderGripper', $nameColumn.Header)
        Assert-True ($columns.Count -eq 5 -and $columns.Contains($nameColumn) -and -not $nameGripper.IsEnabled -and
            [Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and $scroll.ScrollableWidth -lt 1 -and
            $nameColumn.Width -gt $originalNameWidth -and [object]::ReferenceEquals($itemsBeforeToggle, $list.ItemsSource) -and
            [object]::ReferenceEquals($selectedBeforeToggle, $list.SelectedItem)) 'Hiding right columns did not expand Name or preserved rows and selection.'
        $window.Width += 100
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        Assert-True ([Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and $scroll.ScrollableWidth -lt 1) 'Name did not fill the viewport after resizing with right columns hidden.'
        $window.Width -= 100
        $window.Width = 500
        $window.UpdateLayout()
        $controlsScroll = $view.FindName('ViewControlsScroll')
        Assert-True ($controlsScroll.ScrollableWidth -gt 0 -and $controlsScroll.ComputedHorizontalScrollBarVisibility -eq 'Visible') 'The view controls were not scrollable in a narrow pane.'
        $controlsScroll.ScrollToRightEnd()
        $window.UpdateLayout()
        $controlsScroll.ScrollToHome()
        $window.Width = $originalWindowWidth
        $window.UpdateLayout()
        $rightColumnsToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $window.UpdateLayout()
        $widthSum = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
        $toggleIndex = $columns.IndexOf($view.FindName('RightColumnsToggleColumn'))
        Assert-True ($columns.Count -eq 8 -and $columns.IndexOf($typeColumn) -eq $toggleIndex + 1 -and
            $columns.IndexOf($sizeColumn) -eq $toggleIndex + 2 -and $columns.IndexOf($view.FindName('DateColumn')) -eq $toggleIndex + 3 -and $nameGripper.IsEnabled -and
            [Math]::Abs($typeColumn.Width - $originalTypeWidth) -lt 1 -and [Math]::Abs($widthSum - $scroll.ViewportWidth) -lt 1 -and
            [object]::ReferenceEquals($selectedBeforeToggle, $list.SelectedItem)) 'Restoring right columns did not preserve their order, splitter and selection.'
        $list.SelectedItems.Clear()
        $iconSetType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
        $iconSet = $iconSetType.GetConstructor([type[]] @([System.Windows.Media.ImageSource], [System.Windows.Media.ImageSource], [double])).Invoke(
            [object[]] @($notes.Icons.BaseIcon, $notes.MediaTypeIcon, [double] 0.55))
        $entryType = $assembly.GetType('SUTWinExplorer.FileEntry', $true)
        $testEntry = $entryType.GetConstructors()[0].Invoke([object[]] @(
            $notes.Name, $notes.FullPath, $notes.IsDirectory, $notes.Type, $notes.SizeText,
            $notes.Modified, $iconSet, $notes.MediaTypeIcon, $notes.MediaTypeName))
        $rowType = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true)
        $testRow = [Activator]::CreateInstance($rowType, $true)
        $rowType.GetProperty('Entry').SetValue($testRow, $testEntry)
        $cells = foreach ($column in @($view.FindName('TypeApp1Icon'), $modifierColumn)) {
            $presenter = [System.Windows.Controls.ContentPresenter]::new()
            $presenter.Content = $testRow
            $presenter.ContentTemplate = $column.CellTemplate
            $presenter.Measure([System.Windows.Size]::new(16, 16))
            $presenter.Arrange([System.Windows.Rect]::new(0, 0, 16, 16))
            $presenter.UpdateLayout()
            [System.Windows.Media.VisualTreeHelper]::GetChild($presenter, 0)
        }
        $baseCell = $cells[0]
        $overlayCell = $cells[1]
        Assert-True ([object]::ReferenceEquals($baseCell.Source, $notes.Icons.BaseIcon) -and
            [object]::ReferenceEquals($overlayCell.Source, $notes.MediaTypeIcon) -and
            $baseCell.Opacity -eq 0.55 -and $overlayCell.Opacity -eq 0.55) "Shell column binding mismatch: base=$([object]::ReferenceEquals($baseCell.Source, $notes.Icons.BaseIcon)), overlay=$([object]::ReferenceEquals($overlayCell.Source, $notes.MediaTypeIcon)), opacity=$($baseCell.Opacity)/$($overlayCell.Opacity)."
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
        Assert-True $probe.Ready "Background packages did not complete: $($probe.Error)"
        $list.SelectedItems.Add($list.Items[0]) | Out-Null
        $list.SelectedItems.Add($list.Items[$list.Items.Count - 1]) | Out-Null
        $selectedEntries = @($list.SelectedItems | ForEach-Object { $_.Entry })
        $selectedPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($list.SelectedItems.Count -eq 2 -and $view.FindName('CopyMarkItemButton').IsEnabled -and
            $view.FindName('NameClipboardCopyButton').IsEnabled -and $view.FindName('PathClipboardCopyButton').IsEnabled -and -not $view.FindName('RenameButton').IsEnabled) 'Multiple selection or its toolbar state failed.'
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
        $otherView = [Activator]::CreateInstance($view.GetType())
        $otherToggle = $otherView.FindName('RightColumnsToggleHeader')
        $otherToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-True ($otherView.FindName('FileList').View.Columns.Count -eq 5 -and $columns.Count -eq 8) 'Right-column visibility leaked between ContentViews.'
        $otherToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $null = $otherView.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($otherView, [object[]] @([string] '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'))
        Assert-True (-not $otherView.FindName('NewButton').IsEnabled) 'New was enabled for the virtual This PC location.'
        $otherSort = $otherView.GetType().GetField('_sorting', $viewFlags).GetValue($otherView)
        Assert-True ((@($pairsProperty.GetValue($otherSort)).Column -join ',') -ceq $defaultOrder -and
            @($pairsProperty.GetValue($otherSort) | Where-Object { $_.Criterion -ne 'Ascending' }).Count -eq 0) 'Sort history leaked into another ContentView.'
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
        foreach ($selectedEntry in $selectedEntries) {
            $restoredEntry = @($list.SelectedItems | ForEach-Object { $_.Entry } | Where-Object { $_.FullPath -eq $selectedEntry.FullPath })[0]
            Assert-True ([object]::ReferenceEquals($selectedEntry, $restoredEntry)) 'GUI sorting or filtering reloaded a cached entry.'
        }
        foreach ($operation in @('Copy', 'Move')) {
            $view.FindName("${operation}MarkItemButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $workflowType = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true)
            $workflow = $workflowType.GetProperty('Shared').GetValue($null)
            $preparedPaths = @($workflow.PreparedPaths)
            Assert-True ($preparedPaths.Count -eq 2 -and @($selectedPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "$operation did not stage all selected paths."
            $view.FindName("${operation}AbortButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $menuProbe = [SutShellMenuProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($window).Handle)
        try {
            $showItems = $shell.GetMethod('ShowItemMenu', $flags)
            $null = $showItems.Invoke($null, [object[]] @([string[]] $selectedPaths,
                [System.Windows.Interop.WindowInteropHelper]::new($window).Handle, $null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The Shell did not display a populated multi-item context menu.'
        } finally { $menuProbe.Dispose() }
        $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $otherFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'exact.bin') })[0]
        $showMenu = $view.GetType().GetMethod('ShowMenu', $viewFlags)
        $ownerHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $menuInstanceType = $assembly.GetType('SUTWinExplorer.SutContextMenu', $true)
        $showInstance = $menuInstanceType.GetMethod('Show', $viewFlags)
        $emptyActions = [Array]::CreateInstance($assembly.GetType('SUTWinExplorer.ShellMenuAction', $true), 0)
        $factoryPaths = [string[]] @((Join-Path $directory 'notes.txt'))
        $baseInstance = $menuType.GetMethod('GetBaseMenu', $flags).Invoke($null, [object[]] @($factoryPaths, $ownerHandle, $emptyActions))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $baseSnapshot = $showInstance.Invoke($baseInstance, [object[]] @($null))
            Assert-True ($menuProbe.ItemCount -gt 0 -and $null -ne $baseSnapshot) 'The factory Base Menu did not return a snapshot after display.'
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $baseInstance).Dispose()
            ([IDisposable] $baseInstance).Dispose()
        }
        $disposedRejected = $false
        try { $null = $showInstance.Invoke($baseInstance, [object[]] @($null)) } catch {
            $disposedRejected = $_.Exception.InnerException -is [ObjectDisposedException]
        }
        Assert-True $disposedRejected 'A disposed menu instance was still usable.'
        $contentInstance = $menuType.GetMethod('GetContentMenu', $flags).Invoke($null, [object[]] @($factoryPaths, $ownerHandle, $baseSnapshot))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showInstance.Invoke($contentInstance, [object[]] @($null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The Content Menu could not use the snapshot after the Base Menu was disposed.'
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $contentInstance).Dispose()
        }
        $backgroundEntries = @((& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $directory -Background | ConvertFrom-Json).Menu)
        $excludedBackgroundEntries = @($backgroundEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('refresh', 'viewcustomwizard') })
        Assert-True ($excludedBackgroundEntries.Count -eq 2) 'The Shell did not expose both background commands to exclude.'
        $viewParents = @($backgroundEntries | Where-Object {
            $_.Position -match '^\d+\.\d+$' -and $_.Verb -match '^(viewlogical|arrange|sortascending|sortdescending|groupascending|groupdescending)'
        } | ForEach-Object { ($_.Position -split '\.')[0] } | Select-Object -Unique)
        Assert-True ($viewParents.Count -ge 3) 'The Shell did not expose identifiable View, Sort and Group submenus.'
        $newParent = @($backgroundEntries | Where-Object { $_.Position -notmatch '\.' -and $_.HasSubmenu -and $_.OwnerDrawn } | ForEach-Object {
            $parent = $_
            if (@($backgroundEntries | Where-Object { $_.Position -eq ($parent.Position + '.0') -and $_.Text -ceq $parent.Text }).Count -gt 0) { $parent }
        })
        Assert-True ($newParent.Count -eq 1) 'The Shell New submenu could not be identified.'
        Assert-True ($view.FindName('NewButton').IsEnabled -and $view.FindName('PropertiesButton').IsEnabled) 'Directory New or multi-selection Properties state was incorrect.'
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
        Assert-True $probe.Ready 'The content list did not reload after the directory filter changed.'
        $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $otherFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'exact.bin') })[0]
        $newProbe = Start-NewDialogProbe 'Windows'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $view.FindName('NewButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ($newProbe.Seen -and $null -eq $newProbe.Error -and $menuProbe.ItemCount -gt 1) 'The explicit Windows fallback did not open the native New submenu.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
        $list.SelectedItems.Clear()
        Assert-True (-not $view.FindName('PropertiesButton').IsEnabled) 'Properties was enabled without a selection.'
        $list.SelectedItem = $notesMenuRow
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
        $list.SelectedItems.Clear()
        $list.SelectedItems.Add($notesMenuRow) | Out-Null
        $list.SelectedItems.Add($otherFileRow) | Out-Null
        $emptyCommands = [System.Collections.Generic.Dictionary[string, int]]::new()
        $backgroundInstance = $menuType.GetMethod('GetBackgroundContentMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $emptyCommands, $null))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showInstance.Invoke($backgroundInstance, [object[]] @($null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The filtered background menu was not displayed.'
            Assert-True ($newParent[0].Text -in $menuProbe.Items) 'The New submenu was removed from the background Content Menu.'
            $backgroundVerbs = @(Get-ShellMenuVerbs $backgroundInstance)
            foreach ($entry in $excludedBackgroundEntries) {
                Assert-True ($entry.Verb -notin $backgroundVerbs) "An excluded command remained in the background Content Menu: $($entry.Verb)."
            }
            foreach ($position in $viewParents) {
                $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                Assert-True ($parent.Text -notin $menuProbe.Items) "A background view submenu remained: $($parent.Text)."
            }
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $backgroundInstance).Dispose()
        }
        $backgroundBase = $menuType.GetMethod('GetBackgroundBaseMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $emptyActions))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $backgroundSnapshot = $showInstance.Invoke($backgroundBase, [object[]] @($null))
            Assert-True ($null -ne $backgroundSnapshot -and $newParent[0].Text -notin $menuProbe.Items) 'The background Base Menu included New or did not return a snapshot.'
            $backgroundVerbs = @(Get-ShellMenuVerbs $backgroundBase)
            foreach ($entry in $excludedBackgroundEntries) {
                Assert-True ($entry.Verb -notin $backgroundVerbs) "An excluded command remained in the background Base Menu: $($entry.Verb)."
            }
            foreach ($position in $viewParents) {
                $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                Assert-True ($parent.Text -notin $menuProbe.Items) "A background view submenu remained in the Base Menu: $($parent.Text)."
            }
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $backgroundBase).Dispose()
        }
        $backgroundInstance = $menuType.GetMethod('GetBackgroundContentMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $backgroundSnapshot, $null))
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showInstance.Invoke($backgroundInstance, [object[]] @($null))
            Assert-True ($newParent[0].Text -in $menuProbe.Items) 'New was lost after comparing the background menus.'
            $backgroundVerbs = @(Get-ShellMenuVerbs $backgroundInstance)
            foreach ($entry in $excludedBackgroundEntries) {
                Assert-True ($entry.Verb -notin $backgroundVerbs) "An excluded command returned after comparing background menus: $($entry.Verb)."
            }
        } finally {
            $menuProbe.Dispose()
            ([IDisposable] $backgroundInstance).Dispose()
        }
        $backgroundSuffix = [guid]::NewGuid().ToString('N')
        $sharedBackgroundVerb = "KISBackgroundShared$backgroundSuffix"
        $backgroundOnlyVerb = "KISBackgroundOnly$backgroundSuffix"
        $sharedBackgroundLabel = "KIS shared background $backgroundSuffix"
        $backgroundOnlyLabel = "KIS background only $backgroundSuffix"
        $backgroundRegistryPaths = @("Software\Classes\*\shell\$sharedBackgroundVerb",
            "Software\Classes\Directory\shell\$sharedBackgroundVerb",
            "Software\Classes\Directory\Background\shell\$sharedBackgroundVerb",
            "Software\Classes\Directory\Background\shell\$backgroundOnlyVerb")
        try {
            foreach ($registryPath in $backgroundRegistryPaths) {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
                try {
                    $entry.SetValue('', $(if ($registryPath.EndsWith($backgroundOnlyVerb)) { $backgroundOnlyLabel } else { $sharedBackgroundLabel }))
                    $command = $entry.CreateSubKey('command')
                    try { $command.SetValue('', 'cmd.exe /c exit 0') } finally { $command.Dispose() }
                } finally { $entry.Dispose() }
            }
            $backgroundBase = $menuType.GetMethod('GetBackgroundBaseMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $emptyActions))
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $backgroundSnapshot = $showInstance.Invoke($backgroundBase, [object[]] @($null))
                $backgroundVerbs = @(Get-ShellMenuVerbs $backgroundBase)
                Assert-True ($sharedBackgroundVerb -in $backgroundVerbs -and $backgroundOnlyVerb -notin $backgroundVerbs) 'Shared and background-only registrations were classified incorrectly in the Base Menu.'
            } finally { $menuProbe.Dispose(); ([IDisposable] $backgroundBase).Dispose() }
            $backgroundInstance = $menuType.GetMethod('GetBackgroundContentMenu', $flags).Invoke($null, [object[]] @([string] $directory, $ownerHandle, $backgroundSnapshot, $null))
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showInstance.Invoke($backgroundInstance, [object[]] @($null))
                $backgroundVerbs = @(Get-ShellMenuVerbs $backgroundInstance)
                Assert-True ($sharedBackgroundVerb -notin $backgroundVerbs -and $backgroundOnlyVerb -in $backgroundVerbs) 'Shared and background-only registrations were classified incorrectly in the Content Menu.'
            } finally { $menuProbe.Dispose(); ([IDisposable] $backgroundInstance).Dispose() }
        } finally {
            foreach ($registryPath in $backgroundRegistryPaths) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false) }
        }
        $showMenuCore = $view.GetType().GetMethod('ShowMenuCore', $viewFlags)
        $list.SelectedItems.Clear()
        foreach ($menuKind in @('base', 'content', 'none', 'base')) {
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($null, $true))
                if ($menuKind -eq 'none') {
                    Assert-True ($menuProbe.ItemCount -eq -1) 'The third background click displayed a menu.'
                } elseif ($menuKind -eq 'base') {
                    Assert-True ((Test-BaseMenu $menuProbe) -and
                        ($menuProbe.States[0] -band 3) -ne 0 -and ($menuProbe.States[2] -band 3) -ne 0 -and ($menuProbe.States[3] -band 3) -ne 0 -and
                        $newParent[0].Text -notin $menuProbe.Items) 'The background Base Menu or its disabled selection actions were incorrect.'
                } else {
                    Assert-True ($menuProbe.ItemCount -gt 0 -and (Get-ActionCommandId 'New' @('New')) -in $menuProbe.CommandIds) 'The background Content Menu did not include New.'
                }
                foreach ($position in $viewParents) {
                    $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                    Assert-True ($parent.Text -notin $menuProbe.Items) "A view submenu appeared in the background $menuKind step."
                }
            } finally { $menuProbe.Dispose() }
        }
        $newProbe = Start-NewDialogProbe 'Cancel'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'New' @('New')
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($null, $true))
            Assert-True ($menuProbe.SelectIndex -ge 0 -and $newProbe.Seen -and $null -eq $newProbe.Error) 'The ContentView background New action did not open the shared dialog.'
        } finally { $newProbe.Timer.Stop(); $menuProbe.Dispose() }
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
        $showMenuCore = $view.GetType().GetMethod('ShowMenuCore', $viewFlags)
        $multiNativeEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $multiPaths | ConvertFrom-Json).Menu
        Assert-True (@($multiNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text }).Count -gt 0) 'The Shell did not provide a properties command for the multi-file selection.'
        foreach ($menuKind in @('base', 'content', 'none', 'base')) {
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                if ($menuKind -eq 'none') {
                    Assert-True ($menuProbe.ItemCount -eq -1) 'The third multi-file click displayed a menu.'
                    continue
                }
                Assert-True ($menuProbe.ItemCount -gt 0) "The multi-file $menuKind menu was empty."
                $isBase = (Test-BaseMenu $menuProbe)
                Assert-True ($isBase -eq ($menuKind -eq 'base')) "The multi-file menu did not alternate to $menuKind."
                $index = Get-MenuActionIndex $menuProbe 'Properties'
                Assert-True (($index -ge 0) -eq ($menuKind -eq 'base')) "Properties was shown in the wrong multi-file menu: $menuKind."
                if ($menuKind -eq 'base') { Assert-True ($index -eq 0 -and ($menuProbe.States[$index] -band 3) -eq 0) 'Properties was missing or disabled in the Base Menu multi-file menu.' }
                if ($menuKind -eq 'content') {
                    $linkDropHereLabel = [SutShellMenuProbe]::LinkDropHereLabel()
                    Assert-True ($null -eq $linkDropHereLabel -or $linkDropHereLabel -notin $menuProbe.Items) 'A drag-and-drop-only Link Shell Extension command appeared in the multi-file menu.'
                    foreach ($entry in $multiNativeEntries | Where-Object { $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename') -and $_.Text }) {
                        Assert-True ($entry.Text -notin $menuProbe.Items) "Excluded Shell command remained in the multi-file menu: $($entry.Text)."
                    }
                }
            } finally { $menuProbe.Dispose() }
        }
        $controller = $view.GetType().GetField('_contextMenu', $viewFlags).GetValue($view)
        $resetController = $controller.GetType().GetMethod('Reset', $viewFlags)
        foreach ($resetMode in @('explicit', 'selection')) {
            $null = $resetController.Invoke($controller, @())
            foreach ($expectedBase in @($true, $false)) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                    $isBase = (Test-BaseMenu $menuProbe)
                    Assert-True ($menuProbe.ItemCount -gt 0 -and $isBase -eq $expectedBase) 'The reset test did not reach the expected menu.'
                } finally { $menuProbe.Dispose() }
            }
            if ($resetMode -eq 'explicit') { $null = $resetController.Invoke($controller, @()) }
            else {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($otherFileRow) | Out-Null
            }
            $nextRow = if ($resetMode -eq 'explicit') { $notesMenuRow } else { $otherFileRow }
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($nextRow.PSObject.BaseObject, $true))
                Assert-True ((Test-BaseMenu $menuProbe)) "A $resetMode reset did not restart with the Base Menu."
            } finally { $menuProbe.Dispose() }
            if ($resetMode -eq 'selection') {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                $list.SelectedItems.Add($otherFileRow) | Out-Null
            }
        }
        $multiProperties = @($multiNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text })[0]
        $propertiesProbe = [SutShellPropertiesProbe]::new('')
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'Properties'
        try {
            $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($menuProbe.SelectIndex -eq 0 -and $propertiesProbe.Opened) 'The Base Menu multi-file properties command did not open a Windows dialog.'
        } finally {
            $menuProbe.Dispose()
            $propertiesProbe.Dispose()
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $notesMenuRow
        $unfilteredMenu = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path (Join-Path $directory 'notes.txt') -Generic | ConvertFrom-Json).Menu
        $notepadEntries = @($unfilteredMenu | Where-Object { $_.Verb -eq 'ANotepad++64' })
        $viewerEntries = @($unfilteredMenu | Where-Object { $_.Verb -eq 'view SUTTextViewer' })
        $propertyEntries = @($unfilteredMenu | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text })
        $shellRenameEntries = @($unfilteredMenu | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'rename' -and $_.Text })
        Assert-True ($propertyEntries.Count -gt 0) 'The Shell did not provide a properties command for the test file.'
        $nativeEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path (Join-Path $directory 'notes.txt') | ConvertFrom-Json).Menu
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showItems.Invoke($null, [object[]] @([string[]] @((Join-Path $directory 'notes.txt')), $ownerHandle, [Action] {}))
            $nativeLabels = @($menuProbe.Items)
            foreach ($entry in $nativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('properties', 'rename') -and $_.Text }) {
                Assert-True ($entry.Text -in $nativeLabels) "The original Windows menu lost $($entry.Verb)."
            }
        } finally { $menuProbe.Dispose() }
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        $originalLeft = $window.Left
        $originalTop = $window.Top
        try {
            $window.Left = 20
            $window.Top = 20
            $window.Activate() | Out-Null
            $list.SelectedItems.Clear()
            $unfilteredCount = $list.Items.Count
            $unfilteredDirectoryCount = $dirCount.Text
            $unfilteredFileCount = $fileCount.Text
            $namePattern = $view.FindName('NamePatternTextBox')
            $namePattern.Text = 'notes*.txt'
            Wait-ListCount $list 1
            Assert-True ($dirCount.Text -eq $unfilteredDirectoryCount -and $fileCount.Text -eq $unfilteredFileCount) 'The displayed counts changed when the name filter was applied.'
            $backgroundPoint = Find-ListBackgroundPoint $list
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $backgroundPoint.X, [int] $backgroundPoint.Y, [int] $backgroundPoint.X, [int] $backgroundPoint.Y)
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    (Get-ActionCommandId 'New' @('New')) -in $rightClickProbe.SecondCommandIds -and $rightClickProbe.NoMenuObserved -and
                    $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0] -and
                    $list.SelectedItems.Count -eq 0) 'Actual background clicks did not follow the Base, Content, no-menu sequence.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $controller = $view.GetType().GetField('_contextMenu', $viewFlags).GetValue($view)
            $null = $controller.GetType().GetMethod('Reset', $viewFlags).Invoke($controller, @())
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $backgroundPoint.X, [int] $backgroundPoint.Y, [int] $backgroundPoint.X, [int] $backgroundPoint.Y)
            $rightClickProbe.SecondWithShift = $true
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase) 'Shift-right-click did not open the native background menu.'
                foreach ($entry in $excludedBackgroundEntries) {
                    Assert-True ($entry.Text -in $rightClickProbe.SecondItems) "Shift-right-click did not preserve the native background command: $($entry.Text)."
                }
                foreach ($position in $viewParents) {
                    $parent = @($backgroundEntries | Where-Object { $_.Position -eq $position })[0]
                    Assert-True ($parent.Text -in $rightClickProbe.SecondItems) 'Shift-right-click did not preserve the original background view menus.'
                }
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $singleRow = $list.Items[0]
            $list.ScrollIntoView($singleRow)
            $list.UpdateLayout()
            $singleContainer = $list.ItemContainerGenerator.ContainerFromItem($singleRow)
            Assert-True ($null -ne $singleContainer) 'The filtered row was not realized for the background target-change test.'
            $singlePoint = $singleContainer.PointToScreen([System.Windows.Point]::new(10, $singleContainer.ActualHeight / 2))
            foreach ($direction in @('background-to-item', 'item-to-background')) {
                $list.SelectedItems.Clear()
                $null = $controller.GetType().GetMethod('Reset', $viewFlags).Invoke($controller, @())
                $start = if ($direction -eq 'background-to-item') { $backgroundPoint } else { $singlePoint }
                $destination = if ($direction -eq 'background-to-item') { $singlePoint } else { $backgroundPoint }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $start.X, [int] $start.Y, [int] $destination.X, [int] $destination.Y)
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedSelections = if ($direction -eq 'background-to-item') { 1 } else { 0 }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                        $list.SelectedItems.Count -eq $expectedSelections) "A $direction click did not start a new Base Menu."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            $namePattern.Clear()
            Wait-ListCount $list $unfilteredCount
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
            Assert-True $probe.Ready 'The unfiltered rows did not reload after the background click test.'
            $notesMenuRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
            $otherFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'exact.bin') })[0]
            $notesIndex = $list.Items.IndexOf($notesMenuRow)
            $otherMenuRow = $list.Items[($notesIndex + 1) % $list.Items.Count]
            $list.ScrollIntoView($otherMenuRow)
            $list.UpdateLayout()
            $notesContainer = $list.ItemContainerGenerator.ContainerFromItem($notesMenuRow)
            $otherContainer = $list.ItemContainerGenerator.ContainerFromItem($otherMenuRow)
            Assert-True ($null -ne $notesContainer -and $null -ne $otherContainer) 'The right-click test rows were not realized.'
            $startX = [Math]::Min($notesContainer.ActualWidth - 10, $list.ActualWidth - [System.Windows.SystemParameters]::VerticalScrollBarWidth - 12)
            $startPoint = $notesContainer.PointToScreen([System.Windows.Point]::new($startX, $notesContainer.ActualHeight / 2))
            $samePoint = $notesContainer.PointToScreen([System.Windows.Point]::new(10, $notesContainer.ActualHeight / 2))
            $otherPoint = $otherContainer.PointToScreen([System.Windows.Point]::new(10, $otherContainer.ActualHeight / 2))
            $startInList = $list.PointFromScreen($startPoint)
            Assert-True ($startInList.X -lt $list.ActualWidth -and $startInList.X -ge 0) "The right-click start point is outside the visible table: x=$($startInList.X), table=$($list.ActualWidth), row=$($notesContainer.ActualWidth)."
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y, [int] $samePoint.X, [int] $samePoint.Y)
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase) "Two actual right-clicks on the same row did not show the Content Menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y, [int] $samePoint.X, [int] $samePoint.Y)
            $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddMilliseconds($rightClickProbe.SecondDelayMilliseconds + 7000)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $rightClickProbe.TargetClass -eq '#32768') "A delayed right-click at the popup's opening point did not show the Content Menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            foreach ($mode in @('delayed', 'rapid-multi')) {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                if ($mode -eq 'rapid-multi') { $list.SelectedItems.Add($otherMenuRow) | Out-Null }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y, [int] $samePoint.X, [int] $samePoint.Y)
                if ($mode -eq 'delayed') { $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250 }
                $rightClickProbe.AdditionalClicks = 2
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddMilliseconds(3 * $rightClickProbe.SecondDelayMilliseconds + 7000)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedCount = if ($mode -eq 'rapid-multi') { 2 } else { 1 }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                        $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and
                        $rightClickProbe.AdditionalMenuWasBase[0] -and $list.SelectedItems.Count -eq $expectedCount -and
                        $list.SelectedItems.Contains($notesMenuRow) -and ($mode -ne 'rapid-multi' -or $list.SelectedItems.Contains($otherMenuRow))) "Repeated stationary right-clicks did not alternate menus for mode=$mode`: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), additional=$($rightClickProbe.AdditionalMenuCount), selection=$($list.SelectedItems.Count)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $startPoint.X, [int] $startPoint.Y, [int] $otherPoint.X, [int] $otherPoint.Y)
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) "Actual right-clicks on different rows did not select the new row and open its Base Menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($list.SelectedItems.Count), selected=$($list.SelectedItem.Entry.FullPath)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            foreach ($target in @('same', 'selected')) {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                if ($target -eq 'selected') { $list.SelectedItems.Add($otherMenuRow) | Out-Null }
                $targetPoint = if ($target -eq 'same') { $samePoint } else { $otherPoint }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $startPoint.X, [int] $startPoint.Y, [int] $targetPoint.X, [int] $targetPoint.Y)
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddSeconds(7)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedRow = if ($target -eq 'same') { $notesMenuRow } else { $otherMenuRow }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and
                        $rightClickProbe.SecondWasBase -eq ($target -eq 'selected') -and $list.SelectedItems.Count -eq 1 -and
                        $list.SelectedItem.Entry.FullPath -eq $expectedRow.Entry.FullPath) "Actual right-clicks failed for target=$target`: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($list.SelectedItems.Count)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            foreach ($target in @('same', 'other', 'double', 'delayed')) {
                $list.SelectedItems.Clear()
                $list.SelectedItems.Add($notesMenuRow) | Out-Null
                $list.SelectedItems.Add($otherMenuRow) | Out-Null
                $origin = if ($target -in @('double', 'delayed')) { $samePoint } else { $startPoint }
                $targetPoint = if ($target -eq 'other') { $otherPoint } else { $samePoint }
                $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $origin.X, [int] $origin.Y, [int] $targetPoint.X, [int] $targetPoint.Y)
                $rightClickProbe.SecondWithShift = $true
                if ($target -eq 'delayed') { $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250 }
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                $deadline = [DateTime]::UtcNow.AddMilliseconds($rightClickProbe.SecondDelayMilliseconds + 7000)
                $timer = [System.Windows.Threading.DispatcherTimer]::new()
                $timer.Interval = [TimeSpan]::FromMilliseconds(50)
                $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
                $timer.Start()
                try {
                    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                    $expectedCount = if ($target -eq 'other') { 1 } else { 2 }
                    $expectedProperty = if ($target -eq 'other') { $propertyEntries[0].Text } else { $multiProperties.Text }
                    Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                        $expectedProperty -in $rightClickProbe.SecondItems -and $list.SelectedItems.Count -eq $expectedCount -and
                        ($target -ne 'other' -or $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath)) "Shift-right-click during the Base Menu failed for target=$target`: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), properties=$($expectedProperty -in $rightClickProbe.SecondItems), selection=$($list.SelectedItems.Count)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $samePoint.X, [int] $samePoint.Y)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase) 'A second right-click on the same row did not show the Content Menu.'
            } finally { $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $otherPoint.X, [int] $otherPoint.Y)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) 'A right-click on another row did not select it and show its Base Menu.'
            } finally { $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($notesMenuRow) | Out-Null
            $list.SelectedItems.Add($otherMenuRow) | Out-Null
            $list.ScrollIntoView($otherMenuRow)
            $list.UpdateLayout()
            $notesContainer = $list.ItemContainerGenerator.ContainerFromItem($notesMenuRow)
            $otherContainer = $list.ItemContainerGenerator.ContainerFromItem($otherMenuRow)
            $startPoint = $notesContainer.PointToScreen([System.Windows.Point]::new($notesContainer.ActualWidth - 10, $notesContainer.ActualHeight / 2))
            $otherPoint = $otherContainer.PointToScreen([System.Windows.Point]::new(10, $otherContainer.ActualHeight / 2))
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $otherPoint.X, [int] $otherPoint.Y)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and $rightClickProbe.SecondWasBase -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) "A right-click on another selected row did not start a new single-item menu: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($list.SelectedItems.Count), selected=$($list.SelectedItem.Entry.FullPath), target=$($otherMenuRow.Entry.FullPath)."
            } finally { $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($notesMenuRow) | Out-Null
            $list.SelectedItems.Add($otherMenuRow) | Out-Null
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True (Test-BaseMenu $menuProbe) 'The first menu did not open for the multiple selection.'
            } finally { $menuProbe.Dispose() }
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            try {
                $rightClick = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Right)
                $rightClick.RoutedEvent = [System.Windows.Input.Mouse]::PreviewMouseDownEvent
                $otherContainer.RaiseEvent($rightClick)
                Assert-True ((Test-BaseMenu $menuProbe) -and
                    $list.SelectedItems.Count -eq 1 -and $list.SelectedItem.Entry.FullPath -eq $otherMenuRow.Entry.FullPath) "A right-click on another selected row after dismissing the menu did not start a new single-item menu: menu=$($menuProbe.ItemCount), selection=$($list.SelectedItems.Count), selected=$($list.SelectedItem.Entry.FullPath), handled=$($rightClick.Handled)."
            } finally { $menuProbe.Dispose() }
            $copyWorkflow = $assembly.GetType('SUTWinExplorer.CopyWorkflowState', $true).GetProperty('Shared').GetValue($null)
            Assert-True (-not $copyWorkflow.IsPrepared) 'The second right-click activated Copy mark item.'
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
            [SutShellRightClickProbe]::MovePointer([int] $startPoint.X, [int] $startPoint.Y)
            $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
            $menuProbe.SelectCommandId = Get-ActionCommandId 'CopyMarkItem'
            $menuProbe.SelectWithRightButton = $true
            try {
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                Assert-True ($menuProbe.ItemCount -ge 3 -and -not $copyWorkflow.IsPrepared) 'A right-click on a menu command unexpectedly invoked it.'
            } finally {
                $menuProbe.Dispose()
                $view.FindName('CopyAbortButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
        } finally {
            $window.Left = $originalLeft
            $window.Top = $originalTop
            [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1])
            $list.SelectedItems.Clear()
            $list.SelectedItem = $notesMenuRow
        }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            Assert-True ((Test-BaseMenu $menuProbe)) 'The first right-click did not show the Base Menu.'
            $baseLabels = @($menuProbe.Items)
            $index = Get-MenuActionIndex $menuProbe 'Properties'
            Assert-True ($index -eq 0 -and ($menuProbe.States[$index] -band 3) -eq 0) 'Properties was missing or disabled in the Base Menu.'
            foreach ($entry in $shellRenameEntries) {
                $shellLabels = @(for ($index = 0; $index -lt $menuProbe.ItemCount; $index++) { if ($menuProbe.CommandIds[$index] -ge 1 -and $menuProbe.CommandIds[$index] -le 0x7fff) { $menuProbe.Items[$index] } })
                Assert-True ($entry.Text -notin $shellLabels) 'The Shell rename command appeared alongside the application Rename action.'
            }
        } finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            $contentLabels = @($menuProbe.Items)
            Assert-True ($menuProbe.ItemCount -gt 0 -and -not (Test-BaseMenu $menuProbe)) 'The second right-click did not show the Content Menu.'
            $linkDropHereLabel = [SutShellMenuProbe]::LinkDropHereLabel()
            Assert-True ($null -eq $linkDropHereLabel -or $linkDropHereLabel -notin $contentLabels) 'A drag-and-drop-only Link Shell Extension command appeared in the Content file menu.'
            $openWithLabel = [SutShellMenuProbe]::OpenWithLabel()
            if ($openWithLabel -in $nativeLabels) { Assert-True ($openWithLabel -in $contentLabels) 'Open With was lost from the Content Menu.' }
            foreach ($entry in $notepadEntries) {
                if ($entry.Text -in $nativeLabels) { Assert-True ($entry.Text -in $contentLabels) 'Notepad++ was lost from the Content Menu.' }
            }
            foreach ($entry in $nativeEntries | Where-Object { $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename', 'properties') -and $_.Text }) {
                Assert-True ($entry.Text -notin $contentLabels) "Excluded Shell command remained in the Content Menu: $($entry.Text)."
            }
            foreach ($label in $nativeLabels | Where-Object { $_ -and $_ -notin $baseLabels }) {
                $excludedLabel = @($nativeEntries | Where-Object { $_.Text -ceq $label -and $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename', 'properties') }).Count -gt 0
                if (-not $excludedLabel) { Assert-True ($label -in $contentLabels) "A native command absent from the Base Menu was lost: $label." }
            }
            foreach ($label in @('7-Zip', 'Norton 360', '&TortoiseGit', 'Pa&th Copy')) {
                $genericParents = @($unfilteredMenu | Where-Object { $_.Position -notmatch '\.' -and $_.Text -ceq $label -and $_.HasSubmenu })
                $nativeParents = @($nativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -ceq $label -and $_.HasSubmenu })
                if ($genericParents.Count -ne 1 -or $nativeParents.Count -ne 1 -or $label -notin $baseLabels -or $label -notin $nativeLabels) { continue }
                $genericPrefix = $genericParents[0].Position + '.'
                $nativePrefix = $nativeParents[0].Position + '.'
                $genericChildren = @($unfilteredMenu | Where-Object { $_.Position.StartsWith($genericPrefix) -and -not $_.Separator })
                $nativeChildren = @($nativeEntries | Where-Object { $_.Position.StartsWith($nativePrefix) -and -not $_.Separator })
                if ($genericChildren.Count -eq 0 -or @($genericChildren | Where-Object { $_.Disabled -or -not $_.Text }).Count -gt 0) { continue }
                $genericSignature = @($genericChildren | ForEach-Object { @($_.Position.Substring($genericPrefix.Length), $_.Text, $_.Verb, $_.HasSubmenu, $_.Disabled) -join '|' }) -join "`n"
                $nativeSignature = @($nativeChildren | ForEach-Object { @($_.Position.Substring($nativePrefix.Length), $_.Text, $_.Verb, $_.HasSubmenu, $_.Disabled) -join '|' }) -join "`n"
                if ($genericSignature -ceq $nativeSignature) {
                    Assert-True ($label -notin $contentLabels) "The matching $label submenu remained in the Content Menu."
                }
            }
        } finally { $menuProbe.Dispose() }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            Assert-True ($menuProbe.ItemCount -eq -1) 'The third right-click displayed a menu.'
        } finally { $menuProbe.Dispose() }
        if ('7-Zip' -in $baseLabels -and '7-Zip' -in $nativeLabels -and '7-Zip' -notin $contentLabels) {
            foreach ($emptySubmenu in @($false, $true)) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.AlterSubmenu = '7-Zip'
                $menuProbe.EmptySubmenu = $emptySubmenu
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                    Assert-True $menuProbe.SubmenuAltered 'The differing-submenu fixture could not be created.'
                } finally { $menuProbe.Dispose() }
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
                    Assert-True ('7-Zip' -in $menuProbe.Items) 'A submenu with extra Content Menu commands or an empty Base Menu counterpart was removed.'
                } finally { $menuProbe.Dispose() }
                $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            }
        }
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showMenuCore.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject, $true))
            Assert-True ((Test-BaseMenu $menuProbe)) 'The next right-click did not return to the Base Menu.'
        } finally { $menuProbe.Dispose() }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $notesMenuRow
        $propertiesProbe = [SutShellPropertiesProbe]::new('notes.txt')
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'Properties'
        try {
            $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($menuProbe.SelectIndex -eq 0 -and $propertiesProbe.Opened) "The Base Menu properties command did not open the Windows properties dialog: index=$($menuProbe.SelectIndex), opened=$($propertiesProbe.Opened)."
        } finally {
            $menuProbe.Dispose()
            $propertiesProbe.Dispose()
        }
        $contextMenuType = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
        $blacklist = $contextMenuType.GetField('BlacklistedVerbs', [System.Reflection.BindingFlags]'Static,NonPublic').GetValue($null).Value
        Assert-True ($blacklist.Contains('anotepad++64') -and -not $blacklist.Contains('view SUTTextViewer')) 'The embedded blacklist did not load the expected case-insensitive verbs.'
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        try {
            $null = $showItems.Invoke($null, [object[]] @([string[]] @((Join-Path $directory 'notes.txt')), $ownerHandle, $null))
            foreach ($entry in $notepadEntries) {
                Assert-True ($entry.Text -in $menuProbe.Items) 'The original Windows menu lost the Notepad++ command.'
            }
        } finally { $menuProbe.Dispose() }
        $originalClipboard = [System.Windows.Clipboard]::GetDataObject()
        try {
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
            foreach ($operation in @('Copy', 'Move')) {
                $sourceFile = Join-Path $pasteSource "menu-$operation-test.txt"
                $destinationFile = Join-Path $directory "menu-$operation-test.txt"
                [System.IO.File]::WriteAllText($sourceFile, 'menu workflow test')
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $workflow.Prepare([string[]] @($sourceFile))
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                $menuProbe.SelectCommandId = Get-ActionCommandId "${operation}Execute"
                try {
                    $null = $showMenu.Invoke($view, [object[]] @($notesMenuRow.PSObject.BaseObject))
                    Assert-True (($menuProbe.States[$menuProbe.SelectIndex] -band 3) -eq 0) "$operation execute was disabled."
                } finally { $menuProbe.Dispose() }
                Assert-True ([System.IO.File]::Exists($destinationFile) -and -not $workflow.IsPrepared) "$operation execute did not complete the prepared workflow."
                Assert-True (([System.IO.File]::Exists($sourceFile)) -eq ($operation -eq 'Copy')) "$operation execute did not preserve the expected source state."
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
        $list.SelectedItems.Clear()
        foreach ($selectedPath in $selectedPaths) {
            $list.SelectedItems.Add(@($list.Items | Where-Object { $_.Entry.FullPath -eq $selectedPath })[0]) | Out-Null
        }
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
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
        $restoredPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($probe.Ready -and $restoredPaths.Count -eq 2 -and
            @($selectedPaths | Where-Object { $_ -notin $restoredPaths }).Count -eq 0) "Multiple selection was not restored after consecutive refreshes: $($probe.Error)"
        $list.SelectedItems.Clear()
        $firstRow = $list.Items[0]
        $lastRow = $list.Items[$list.Items.Count - 1]
        $list.ScrollIntoView($lastRow)
        $list.UpdateLayout()
        $priority = [SutShellPriorityProbe]::new()
        $priority.First = $firstRow
        $priority.Visible = $lastRow
        $priorityCallback = [Delegate]::CreateDelegate([System.ComponentModel.PropertyChangedEventHandler], $priority, 'OnPropertyChanged')
        $firstRow.add_PropertyChanged($priorityCallback)
        $lastRow.add_PropertyChanged($priorityCallback)
        try {
            $firstRow.GetType().GetProperty('Entry').SetValue($firstRow, $null)
            $lastRow.GetType().GetProperty('Entry').SetValue($lastRow, $null)
            $view.GetType().GetField('_nextBackgroundIndex', $viewFlags).SetValue($view, 0)
            $null = $view.GetType().GetMethod('LoadNextRange', $viewFlags).Invoke($view, @())
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
            Assert-True ($probe.Ready -and $priority.Order -ceq 'VB') "Visible row did not precede background work: $($priority.Order) $($probe.Error)"
        } finally {
            $firstRow.remove_PropertyChanged($priorityCallback)
            $lastRow.remove_PropertyChanged($priorityCallback)
        }
        $list.ScrollIntoView($firstRow)
        $list.UpdateLayout()
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Scrolling did not load and render the requested range: $($probe.Error)"
        $list.SelectedItem = $list.Items[0]
        Assert-True ($view.FindName('NameClipboardCopyButton').IsEnabled -and $view.FindName('PathClipboardCopyButton').IsEnabled) 'Selecting a loaded row must enable Name clipboard copy and Path clipboard copy.'
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
        Assert-True $probe.Ready "Rows were not ready for rename testing: $($probe.Error)"
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
        $view.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
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
        Assert-True $probe.Ready 'Directory rows were not loaded for rename testing.'
        $folderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'Folder') })[0]
        $renamedFileRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt') })[0]
        Assert-True ($null -ne $folderRow -and $null -ne $renamedFileRow) 'Mixed-selection rows were not available.'
        $otherFolderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'OtherFolder') })[0]
        Assert-True ($null -ne $otherFolderRow) 'The second directory menu test row was not loaded.'
        $registrySuffix = [guid]::NewGuid().ToString('N')
        $sharedVerb = "KISTestShared$registrySuffix"
        $folderSharedVerb = "KISTestFolderShared$registrySuffix"
        $directoryVerb = "KISTestDirectory$registrySuffix"
        $sharedLabel = "KIS shared action $registrySuffix"
        $folderSharedLabel = "KIS shared folder action $registrySuffix"
        $directoryLabel = "KIS directory action $registrySuffix"
        $registryPaths = @("Software\Classes\*\shell\$sharedVerb", "Software\Classes\Directory\shell\$sharedVerb",
            "Software\Classes\*\shell\$folderSharedVerb", "Software\Classes\Folder\shell\$folderSharedVerb", "Software\Classes\Directory\shell\$directoryVerb")
        try {
            foreach ($registryPath in $registryPaths) {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
                try {
                    $label = if ($registryPath.EndsWith($sharedVerb)) { $sharedLabel } elseif ($registryPath.EndsWith($folderSharedVerb)) { $folderSharedLabel } else { $directoryLabel }
                    $entry.SetValue('', $label)
                    $command = $entry.CreateSubKey('command')
                    try { $command.SetValue('', 'cmd.exe /c exit 0') } finally { $command.Dispose() }
                } finally { $entry.Dispose() }
            }
            $list.SelectedItems.Clear()
            $list.SelectedItem = $folderRow
            foreach ($menuKind in @('base', 'content')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                    Assert-True (($sharedLabel -in $menuProbe.Items) -eq ($menuKind -eq 'base') -and
                        ($folderSharedLabel -in $menuProbe.Items) -eq ($menuKind -eq 'base') -and
                        ($directoryLabel -in $menuProbe.Items) -eq ($menuKind -eq 'content')) "Registry-matched directory commands appeared in the wrong menu: $menuKind."
                } finally { $menuProbe.Dispose() }
            }
            $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
            $whitelist = $menuType.GetField('DirectoryWhitelist', $flags).GetValue($null).Value
            $whitelistedVerbs = $whitelist.GetType().GetProperty('Verbs').GetValue($whitelist)
            $null = $whitelistedVerbs.Add($directoryVerb.ToLowerInvariant())
            try {
                foreach ($menuKind in @('base', 'content')) {
                    $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                    try {
                        $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                        Assert-True (($directoryLabel -in $menuProbe.Items) -eq ($menuKind -eq 'base')) "The whitelisted directory command appeared in the wrong menu: $menuKind."
                    } finally { $menuProbe.Dispose() }
                }
            } finally { $null = $whitelistedVerbs.Remove($directoryVerb) }
            $explorerVerb = "KISTestExplorerCommand$registrySuffix"
            $explorerPath = "Software\Classes\Directory\shell\$explorerVerb"
            try {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($explorerPath)
                try { $entry.SetValue('ExplorerCommandHandler', $testHandler.ToString('B')) } finally { $entry.Dispose() }
                $directoryVerbKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\Directory\shell')
                try {
                    $emptyNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    $getEligibleVerbs = $menuType.GetMethod('GetEligibleDirectoryVerbs', $flags)
                    $accepted = $getEligibleVerbs.Invoke($null, [object[]] @($directoryVerbKey, $emptyNames, $parsedWhitelist))
                    $rejected = $getEligibleVerbs.Invoke($null, [object[]] @($directoryVerbKey, $emptyNames, $whitelist))
                    Assert-True ($accepted.Contains($explorerVerb) -and -not $rejected.Contains($explorerVerb)) 'ExplorerCommandHandler CLSID whitelist matching failed.'
                } finally { $directoryVerbKey.Dispose() }
            } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($explorerPath, $false) }
        } finally {
            foreach ($registryPath in $registryPaths) {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false)
            }
        }
        foreach ($multiple in @($false, $true)) {
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($folderRow) | Out-Null
            if ($multiple) { $list.SelectedItems.Add($otherFolderRow) | Out-Null }
            $folderPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
            $folderNativeEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $folderPaths | ConvertFrom-Json).Menu
            $folderProperties = @($folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -eq 'properties' -and $_.Text })
            Assert-True ($folderProperties.Count -gt 0) "The Shell did not provide directory properties: multiple=$multiple."
            if (-not $multiple) {
                $singleFolderProperty = $folderProperties[0].Text
                $folderFilesystemEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $folderPaths -FilesystemObjects | ConvertFrom-Json).Menu
                $sevenZipNative = @($folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -eq '7-Zip' -and $_.HasSubmenu })
                $sevenZipFileKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('*\shellex\ContextMenuHandlers\7-Zip')
                $sevenZipFolderKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('Folder\shellex\ContextMenuHandlers\7-Zip')
                try {
                    $sevenZipShared = $null -ne $sevenZipFileKey -and $null -ne $sevenZipFolderKey -and
                        $sevenZipFileKey.GetValue('') -eq $sevenZipFolderKey.GetValue('') -and $sevenZipNative.Count -eq 1
                } finally {
                    if ($sevenZipFileKey) { $sevenZipFileKey.Dispose() }
                    if ($sevenZipFolderKey) { $sevenZipFolderKey.Dispose() }
                }
                $hgFileKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('*\shellex\ContextMenuHandlers\TortoiseHgCMenu')
                $hgFolderKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('Folder\shellex\ContextMenuHandlers\TortoiseHgCMenu')
                try {
                    $hgWorkbench = @($folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -match '^Hg\s+&?Workbench$' -and -not $_.Verb -and -not $_.HasSubmenu -and -not $_.OwnerDrawn })
                    $hgShared = $null -ne $hgFileKey -and $null -ne $hgFolderKey -and
                        $hgFileKey.GetValue('') -eq $hgFolderKey.GetValue('') -and $hgWorkbench.Count -eq 1
                } finally {
                    if ($hgFileKey) { $hgFileKey.Dispose() }
                    if ($hgFolderKey) { $hgFolderKey.Dispose() }
                }
            }
            foreach ($menuKind in @('base', 'content', 'none', 'base')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                    if ($menuKind -eq 'none') {
                        Assert-True ($menuProbe.ItemCount -eq -1) 'The third directory click displayed a menu.'
                        continue
                    }
                    $isBase = (Test-BaseMenu $menuProbe)
                    Assert-True ($isBase -eq ($menuKind -eq 'base')) "The directory menu did not alternate to $menuKind`: multiple=$multiple."
                    $index = Get-MenuActionIndex $menuProbe 'Properties'
                    Assert-True (($index -ge 0) -eq ($menuKind -eq 'base')) "Directory properties appeared in the wrong menu: multiple=$multiple, menu=$menuKind."
                    if ($menuKind -eq 'base') { Assert-True ($index -eq 0 -and ($menuProbe.States[$index] -band 3) -eq 0) 'Directory properties was disabled.' }
                    if ($multiple -and $menuKind -eq 'base') {
                        Assert-True (($menuProbe.States[0] -band 3) -eq 0 -and ($menuProbe.States[2] -band 3) -eq 0 -and ($menuProbe.States[3] -band 3) -eq 0 -and ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'Rename')] -band 3) -ne 0) 'Multiple directory selection actions have incorrect states.'
                    }
                    if ($menuKind -eq 'base') {
                        $folderBaseLabels = @($menuProbe.Items)
                        $actions = $view.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($view, @())
                        $baseInstance = $menuType.GetMethod('GetBaseMenuForContext', $flags).Invoke($null, [object[]] @([string[]] $folderPaths, $ownerHandle, $actions, $false))
                        try {
                            $folderBaseVerbs = @(Get-ShellMenuVerbs $baseInstance)
                            $folderBaseSnapshot = $baseInstance.GetType().GetMethod('CaptureSnapshot', $viewFlags).Invoke($baseInstance, @())
                        }
                        finally { ([IDisposable] $baseInstance).Dispose() }
                        if (-not $multiple) {
                            if ($sevenZipShared) { Assert-True ('7-Zip' -in $folderBaseLabels) 'The shared 7-Zip handler was missing from the directory Base Menu.' }
                            if ($hgShared) { Assert-True ($hgWorkbench[0].Text -in $folderBaseLabels) 'The shared Hg Workbench command was missing from the directory Base Menu.' }
                            foreach ($entry in $folderFilesystemEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -and $_.Verb -notin @('copy', 'cut', 'paste', 'copyaspath', 'delete', 'rename', 'properties') }) {
                                Assert-True ($entry.Verb -in $folderBaseVerbs) "An AllFilesystemObjects command was missing from the directory Base Menu: $($entry.Verb)."
                            }
                        }
                    }
                    if ($menuKind -eq 'content') {
                        if (-not $multiple -and $sevenZipShared) { Assert-True ('7-Zip' -notin $menuProbe.Items) 'The shared 7-Zip handler remained duplicated in the directory Content Menu.' }
                        if (-not $multiple -and $hgShared) { Assert-True ($hgWorkbench[0].Text -notin $menuProbe.Items) 'The shared Hg Workbench command remained duplicated in the directory Content Menu.' }
                        $contentInstance = $menuType.GetMethod('GetContentMenuForContext', $flags).Invoke($null, [object[]] @([string[]] $folderPaths, $ownerHandle, $folderBaseSnapshot, $false, $null, $null))
                        try { $folderContentVerbs = @(Get-ShellMenuVerbs $contentInstance) }
                        finally { ([IDisposable] $contentInstance).Dispose() }
                        foreach ($entry in $folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'delete', 'rename') }) {
                            Assert-True ($entry.Verb -notin $folderContentVerbs) "An excluded command remained in the directory Content Menu: $($entry.Verb)."
                        }
                        foreach ($entry in $folderNativeEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -and -not $_.HasSubmenu -and -not $_.Disabled -and -not $_.OwnerDrawn -and $_.Verb -notin $folderBaseVerbs -and $_.Verb -notin @('copy', 'cut', 'paste', 'copyaspath', 'delete', 'rename', 'properties') }) {
                            Assert-True ($entry.Verb -in $folderContentVerbs) "A directory command absent from the Base Menu was lost: $($entry.Verb)."
                        }
                    }
                    Assert-True ($list.SelectedItems.Count -eq $folderPaths.Count) 'Switching directory menus changed the selection.'
                } finally { $menuProbe.Dispose() }
            }
        }
        if ($hgShared) {
            $collisionVerb = "KISTestDirectoryCollision$registrySuffix"
            $collisionPath = "Software\Classes\Directory\shell\$collisionVerb"
            try {
                $entry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($collisionPath)
                try {
                    $entry.SetValue('', $hgWorkbench[0].Text)
                    $command = $entry.CreateSubKey('command')
                    try { $command.SetValue('', 'cmd.exe /c exit 0') } finally { $command.Dispose() }
                } finally { $entry.Dispose() }
                $list.SelectedItems.Clear()
                $list.SelectedItem = $folderRow
                $collisionEntries = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $folderRow.Entry.FullPath | ConvertFrom-Json).Menu
                Assert-True (@($collisionEntries | Where-Object { $_.Position -notmatch '\.' -and $_.Text -ceq $hgWorkbench[0].Text }).Count -eq 2) 'The duplicate-label directory fixture was not shown by the Shell.'
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject, $true))
                    Assert-True (@($menuProbe.Items | Where-Object { $_ -ceq $hgWorkbench[0].Text }).Count -eq 1) 'The ambiguous shared Hg command was lost or the directory-only command was promoted.'
                } finally { $menuProbe.Dispose() }
            } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($collisionPath, $false) }
        }
        $list.SelectedItems.Clear()
        $list.SelectedItem = $folderRow
        $propertiesProbe = [SutShellPropertiesProbe]::new('Folder')
        $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
        $menuProbe.SelectCommandId = Get-ActionCommandId 'Properties'
        try {
            $null = $showMenu.Invoke($view, [object[]] @($folderRow.PSObject.BaseObject))
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($propertiesProbe.Opened -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($menuProbe.SelectIndex -eq 0 -and $propertiesProbe.Opened) 'Directory properties did not open a Windows dialog from the Base Menu.'
        } finally { $menuProbe.Dispose(); $propertiesProbe.Dispose() }
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
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        $originalLeft = $window.Left
        $originalTop = $window.Top
        try {
            $window.Left = 20
            $window.Top = 20
            $window.Activate() | Out-Null
            $list.ScrollIntoView($folderRow)
            $list.UpdateLayout()
            $folderContainer = $list.ItemContainerGenerator.ContainerFromItem($folderRow)
            Assert-True ($null -ne $folderContainer) 'The directory right-click test row was not realized.'
            $folderPoint = $folderContainer.PointToScreen([System.Windows.Point]::new(10, $folderContainer.ActualHeight / 2))
            $list.SelectedItems.Clear()
            $list.SelectedItem = $folderRow
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $folderPoint.X, [int] $folderPoint.Y, [int] $folderPoint.X, [int] $folderPoint.Y)
            $rightClickProbe.SecondDelayMilliseconds = [int] [SutShellRightClickProbe]::GetDoubleClickTime() + 250
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddMilliseconds(3 * $rightClickProbe.SecondDelayMilliseconds + 7000)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and
                    $rightClickProbe.AdditionalMenuWasBase[0] -and $list.SelectedItems.Count -eq 1 -and
                    $list.SelectedItem.Entry.FullPath -eq $folderRow.Entry.FullPath) 'Stationary right-clicks did not alternate the directory menus.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($folderRow) | Out-Null
            $list.SelectedItems.Add($renamedFileRow) | Out-Null
            $rightClickProbe = [SutShellRightClickProbe]::new($ownerHandle, [int] $folderPoint.X, [int] $folderPoint.Y, [int] $folderPoint.X, [int] $folderPoint.Y)
            $rightClickProbe.AdditionalClicks = 2
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.AdditionalMenuCount -eq 1 -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and -not $rightClickProbe.SecondWasBase -and
                    $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0] -and
                    $list.SelectedItems.Count -eq 2 -and $list.SelectedItems.Contains($folderRow) -and
                    $list.SelectedItems.Contains($renamedFileRow)) 'Stationary right-clicks did not alternate the mixed-selection menus.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
        } finally {
            $window.Left = $originalLeft
            $window.Top = $originalTop
            [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1])
        }
        foreach ($firstRow in @($renamedFileRow, $folderRow)) {
            $secondRow = if ($firstRow -eq $folderRow) { $renamedFileRow } else { $folderRow }
            $list.SelectedItems.Clear()
            $list.SelectedItems.Add($firstRow) | Out-Null
            $list.SelectedItems.Add($secondRow) | Out-Null
            $mixedPaths = @($firstRow.Entry.FullPath, $secondRow.Entry.FullPath)
            Assert-True ($list.SelectedItems.Count -eq 2) 'The mixed file and folder selection was not established.'
            $mixedNative = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $mixedPaths | ConvertFrom-Json).Menu
            $mixedGeneric = (& (Join-Path $PSScriptRoot 'ContextMenuSpike.ps1') -Path $mixedPaths -Generic | ConvertFrom-Json).Menu
            Assert-True ($mixedNative.Count -gt 0 -and $mixedGeneric.Count -gt 0) 'The Shell did not provide both mixed-selection menus.'
            foreach ($menuKind in @('base', 'content', 'none', 'base')) {
                $menuProbe = [SutShellMenuProbe]::new($ownerHandle)
                try {
                    $null = $showMenuCore.Invoke($view, [object[]] @($firstRow.PSObject.BaseObject, $true))
                    if ($menuKind -eq 'none') {
                        Assert-True ($menuProbe.ItemCount -eq -1) 'The third mixed-selection click displayed a menu.'
                        continue
                    }
                    $isBase = (Test-BaseMenu $menuProbe)
                    Assert-True ($isBase -eq ($menuKind -eq 'base')) "The mixed menu did not alternate to $menuKind."
                    if ($isBase) {
                        Assert-True (($menuProbe.States[0] -band 3) -eq 0 -and ($menuProbe.States[2] -band 3) -eq 0 -and ($menuProbe.States[3] -band 3) -eq 0 -and
                            ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'CopyMarkItem')] -band 3) -eq 0 -and ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'MoveMarkItem')] -band 3) -eq 0 -and
                            ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'Delete')] -band 3) -eq 0) 'Mixed-selection action states were incorrect.'
                        Assert-True ((Get-MenuActionIndex $menuProbe 'Properties') -eq 0) 'Mixed-selection Base Menu lost Properties.'
                    } else {
                        foreach ($entry in $mixedNative | Where-Object { $_.Position -notmatch '\.' -and $_.Verb -in @('copy', 'cut', 'paste', 'copyaspath', 'link', 'delete', 'rename', 'properties') -and $_.Text }) {
                            Assert-True ($entry.Text -notin $menuProbe.Items) "Excluded Shell command remained in the mixed Content Menu: $($entry.Text)."
                        }
                    }
                    Assert-True ($list.SelectedItems.Count -eq 2 -and $list.SelectedItems.Contains($firstRow) -and
                        $list.SelectedItems.Contains($secondRow)) 'Opening a mixed-selection menu changed the selection.'
                } finally { $menuProbe.Dispose() }
            }
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
        $list.SelectedItem = $folderRow
        $renameProbe = [SutShellRenameProbe]::new()
        $folderEvent = $view.GetType().GetEvent('DirectoryRenamed', $viewFlags)
        $folderCallback = [Delegate]::CreateDelegate([Action[string,string]], $renameProbe, 'OnDirectoryRenamed')
        $folderEvent.GetAddMethod($true).Invoke($view, [object[]] @($folderCallback))
        try {
            $null = $view.GetType().GetMethod('BeginRename', $viewFlags).Invoke($view, @())
            $folderRow.EditName = 'RenamedFolder'
            $null = $view.GetType().GetMethod('EndRename', $viewFlags).Invoke($view, [object[]] @([bool] $true))
            Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'RenamedFolder')) -and
                $renameProbe.OldPath -eq (Join-Path $directory 'Folder') -and
                $renameProbe.NewPath -eq (Join-Path $directory 'RenamedFolder')) 'Directory rename was not propagated.'
        } finally {
            $folderEvent.GetRemoveMethod($true).Invoke($view, [object[]] @($folderCallback))
        }
        $otherDirectory = Join-Path $directory 'navigation-test'
        [System.IO.Directory]::CreateDirectory($otherDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $otherDirectory 'other.txt'), 'other')
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $otherDirectory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and [System.IO.Path]::GetDirectoryName($list.Items[0].Entry.FullPath) -eq $directory) "A stale navigation replaced the current snapshot: $($probe.Error)"

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
            $view.FindName('CopyMarkItemButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
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
    } finally {
        $window.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    'ContentView tests passed.'
} finally {
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}