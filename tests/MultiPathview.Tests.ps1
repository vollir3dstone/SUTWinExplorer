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
[SutShellRightClickProbe]::PropertiesCommandId = Get-ActionCommandId 'Properties'
[SutShellRightClickProbe]::NameClipboardCopyCommandId = Get-ActionCommandId 'NameClipboardCopy'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-multipathview-test-' + [guid]::NewGuid().ToString('N'))

try {
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'OtherFolder')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'RenamedFolder')) | Out-Null
    Assert-True ((Get-ActionCommandId 'Properties') -eq 0x8000) 'The sidebar action order is unavailable.'
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $pathviewType = $assembly.GetType('SUTWinExplorer.Pathview', $true)
    $pathviewConstructor = $pathviewType.GetConstructors()[0]
    $fixedPathview = $pathviewConstructor.Invoke([object[]] @([string] $directory, [bool] $false, $null, $null, $null, $null))
    $browsePathview = $pathviewConstructor.Invoke([object[]] @([string] $directory, [bool] $true, $null, $null, $null, $null))
    $fixedPathview.ShowPathActionButtons = $true
    $fixedPathview.ShowSelectedActionButtons = $true
    $fixedPathview.ShowDirectoryActionButtons = $true
    Assert-True (-not $browsePathview.ShowPathActionButtons -and -not $browsePathview.ShowSelectedActionButtons -and
        -not $browsePathview.ShowDirectoryActionButtons) 'Action group flags must be independent across Pathviews.'
    $fixedPathview.ShowPathActionButtons = $false
    $fixedPathview.ShowSelectedActionButtons = $false
    $fixedPathview.ShowDirectoryActionButtons = $false
    foreach ($pathview in @($fixedPathview, $browsePathview)) {
        $prefix = $pathview.FindName('LocationHeaderPrefix')
        $group = @($prefix.Children | Where-Object { $_ -is [System.Windows.Controls.Grid] })[0]
        Assert-True ($null -ne $group -and $group.ColumnDefinitions.Count -eq 6 -and $group.Background.Color -eq [System.Windows.Media.Color]::FromArgb(77, 0, 0, 0)) 'The Pathview header prefix must have a black six-column background at 30% opacity.'
        Assert-True ([System.Windows.Controls.Grid]::GetColumn($pathview.FindName('OpenInExplorerButton')) -eq 2 -and [System.Windows.Controls.Grid]::GetColumn($pathview.FindName('FixedPathBadge')) -eq 4) 'The Explorer button must follow Browse or Pin and precede the FIXED badge.'
    }
    $fixedWindow = [System.Windows.Window]::new()
    try {
        $fixedWindow.ShowInTaskbar = $false
        $fixedWindow.Left = -20000
        $fixedWindow.Top = -20000
        $fixedWindow.Width = 1600
        $fixedWindow.Height = 650
        $sidebarGrid = [System.Windows.Controls.Grid]::new()
        $sidebarGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
        $sidebarGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
        [System.Windows.Controls.Grid]::SetColumn($browsePathview, 1)
        $null = $sidebarGrid.Children.Add($fixedPathview)
        $null = $sidebarGrid.Children.Add($browsePathview)
        $fixedWindow.Content = $sidebarGrid
        $fixedWindow.Show()
        $fixedWindow.UpdateLayout()
        $fixedBadge = $fixedPathview.FindName('FixedPathBadge')
        $browseButton = $fixedPathview.FindName('BrowsePathviewButton')
        Assert-True ([Math]::Abs($fixedBadge.ActualHeight - $browseButton.ActualHeight) -lt 0.1) 'The FIXED badge must match the Browse button height.'
        $directoryContent = $fixedPathview.FindName('DirectoryContent')
        foreach ($badge in @($directoryContent.FindName('DirectoryBadge'), $directoryContent.FindName('ViewControlsRow').Children[0], $directoryContent.FindName('SelectionControlsRow').Children[0])) {
            Assert-True ($badge.Height -eq $browseButton.Height) 'Content badges must use the shared text-button height.'
        }
        foreach ($case in @(@{ View = $fixedPathview; Button = 'BrowsePathviewButton' }, @{ View = $browsePathview; Button = 'PinPathviewButton' })) {
            $group = @($case.View.FindName('LocationHeaderPrefix').Children | Where-Object { $_ -is [System.Windows.Controls.Grid] })[0]
            $button = $case.View.FindName($case.Button)
            $explorerButton = $case.View.FindName('OpenInExplorerButton')
            $offset = $button.TranslatePoint([System.Windows.Point]::new(0, 0), $group)
            Assert-True ([Math]::Abs($group.ActualHeight - $button.ActualHeight) -lt 0.1 -and [Math]::Abs($offset.Y) -lt 0.1) 'The black header prefix must not extend above or below the button.'
            Assert-True ([Math]::Abs($explorerButton.ActualHeight - $button.ActualHeight) -lt 0.1) 'The Explorer button must match the Browse or Pin button height.'
            $panel = $case.View.FindName('LocationHeaderPanel')
            $prefix = $case.View.FindName('LocationHeaderPrefix')
            $icon = $case.View.FindName('LocationIconSlot')
            $prefixEnd = $prefix.TranslatePoint([System.Windows.Point]::new($prefix.ActualWidth, 0), $panel).X
            $iconStart = $icon.TranslatePoint([System.Windows.Point]::new(0, 0), $panel).X
            Assert-True ([Math]::Abs($iconStart - $prefixEnd - 8) -lt 0.1) 'The path icon must have an 8-DIP gap after the header prefix.'
        }
        $subdirectoryList = $fixedPathview.FindName('ActivePathSubdirectoriesList')
        $subdirectoryEntry = @($subdirectoryList.Items | Where-Object { $_.Path -eq (Join-Path $directory 'OtherFolder') })[0]
        $siblingsTree = $browsePathview.FindName('ActivePathAndSiblingsTree')
        $treeEntry = Find-TreeEntry $siblingsTree.Items[0] (Join-Path $directory 'RenamedFolder')
        Assert-True ($null -ne $subdirectoryEntry -and $null -ne $treeEntry) 'Directory sidebar menu test entries were not found.'
        $showDirectoryMenu = $pathviewType.GetMethod('ShowDirectoryMenu', $viewFlags)
        $sidebarCases = @(@{ View = $fixedPathview; Window = $fixedWindow; Entry = $subdirectoryEntry; Tree = $false },
                          @{ View = $browsePathview; Window = $fixedWindow; Entry = $treeEntry; Tree = $true })
        foreach ($case in $sidebarCases) {
            foreach ($menuKind in @('base', 'content', 'none', 'base')) {
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
                $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($case.Window).Handle
                $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
                try {
                    $null = $showDirectoryMenu.Invoke($case.View, [object[]] @($case.Entry.PSObject.BaseObject, [bool] $case.Tree, [bool] $true))
                    if ($menuKind -eq 'none') {
                        Assert-True ($menuProbe.ItemCount -eq -1) 'The third sidebar click displayed a menu.'
                        continue
                    }
                    $isBase = (Test-BaseMenu $menuProbe)
                    Assert-True ($isBase -eq ($menuKind -eq 'base')) "Sidebar menu did not alternate: tree=$($case.Tree), expected=$menuKind, count=$($menuProbe.ItemCount), path=$($case.Entry.Path), exists=$([IO.Directory]::Exists($case.Entry.Path)), items=$($menuProbe.Items -join '|')."
                    if ($isBase) {
                        Assert-True (($menuProbe.States[0] -band 3) -eq 0 -and ($menuProbe.States[2] -band 3) -eq 0 -and ($menuProbe.States[3] -band 3) -eq 0 -and
                            ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'CopyMarkItem')] -band 3) -eq 0 -and ($menuProbe.States[(Get-MenuActionIndex $menuProbe 'Delete')] -band 3) -eq 0) 'Sidebar directory action states were incorrect.'
                    }
                } finally { $menuProbe.Dispose() }
            }
        }
        foreach ($case in @($sidebarCases[0], $sidebarCases[1], $sidebarCases[0])) {
            $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($case.Window).Handle
            $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
            try {
                $null = $showDirectoryMenu.Invoke($case.View, [object[]] @($case.Entry.PSObject.BaseObject, [bool] $case.Tree, [bool] $true))
                Assert-True (Test-BaseMenu $menuProbe) "Switching sidebar widgets did not reset the menu sequence: tree=$($case.Tree)."
            } finally { $menuProbe.Dispose() }
        }
        foreach ($case in @(@{ View = $fixedPathview; Window = $fixedWindow; Entry = $subdirectoryEntry; Tree = $false },
                            @{ View = $browsePathview; Window = $fixedWindow; Entry = $treeEntry; Tree = $true })) {
            $sidebarOwner = [System.Windows.Interop.WindowInteropHelper]::new($case.Window).Handle
            foreach ($operation in @('Copy', 'Move')) {
                $workflow = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true).GetProperty('Shared').GetValue($null)
                $menuProbe = [SutShellMenuProbe]::new($sidebarOwner)
                $menuProbe.SelectCommandId = Get-ActionCommandId "${operation}MarkItem"
                try {
                    $null = $showDirectoryMenu.Invoke($case.View, [object[]] @($case.Entry.PSObject.BaseObject, [bool] $case.Tree, [bool] $false))
                    Assert-True ($workflow.IsPrepared -and @($workflow.PreparedPaths).Count -eq 1 -and
                        @($workflow.PreparedPaths)[0] -eq $case.Entry.Path) "Sidebar $operation targeted the wrong selection."
                } finally { $menuProbe.Dispose(); $workflow.Abort() }
            }
        }
        $originalCursor = [SutShellRightClickProbe]::CursorPosition()
        try {
            $fixedWindow.Left = 20
            $fixedWindow.Top = 20
            $fixedWindow.Activate() | Out-Null
            $subdirectoryEntry = @($subdirectoryList.Items | Where-Object { $_.Path -eq (Join-Path $directory 'OtherFolder') })[0]
            $treeEntry = Find-TreeEntry $siblingsTree.Items[0] (Join-Path $directory 'RenamedFolder')
            $subdirectoryList.ScrollIntoView($subdirectoryEntry)
            $fixedWindow.UpdateLayout()
            $backgroundLabel = $fixedPathview.FindName('LocationLabel')
            $backgroundPoint = $backgroundLabel.PointToScreen([System.Windows.Point]::new($backgroundLabel.ActualWidth / 2, $backgroundLabel.ActualHeight / 2))
            $rightClickProbe = [SutShellRightClickProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle,
                [int] $backgroundPoint.X, [int] $backgroundPoint.Y, [int] $backgroundPoint.X, [int] $backgroundPoint.Y)
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
                    $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0]) 'Pathview background clicks did not follow the three-step sequence.'
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            $subdirectoryContainer = $subdirectoryList.ItemContainerGenerator.ContainerFromItem($subdirectoryEntry)
            $treeContainer = Find-TreeContainer $siblingsTree $treeEntry
            Assert-True ($null -ne $subdirectoryContainer -and $null -ne $treeContainer) "Sidebar right-click test entries were not realized: list=$($null -ne $subdirectoryContainer), tree=$($null -ne $treeContainer), treeEntry=$($null -ne $treeEntry)."
            foreach ($container in @($subdirectoryContainer, $treeContainer)) {
                $container.BringIntoView()
                $fixedWindow.UpdateLayout()
                $point = $container.PointToScreen([System.Windows.Point]::new(10, $container.ActualHeight / 2))
                $rightClickProbe = [SutShellRightClickProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($fixedWindow).Handle,
                    [int] $point.X, [int] $point.Y, [int] $point.X, [int] $point.Y)
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
                        $rightClickProbe.NoMenuObserved -and $rightClickProbe.AdditionalMenuCount -eq 1 -and $rightClickProbe.AdditionalMenuWasBase[0]) "Sidebar right-click alternation failed: first=$($rightClickProbe.FirstMenu), second=$($rightClickProbe.SecondMenu)."
                } finally { $timer.Stop(); $rightClickProbe.Dispose() }
            }
        } finally { [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1]) }
    } finally {
        $fixedWindow.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    'MultiPathview tests passed.'
} finally {
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}