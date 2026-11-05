$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public sealed class DirectoryNotificationProbe
{
    public string DirectoryPath;
    public string OldPath;
    public string NewPath;
    public void OnChanged(object sender, object notification)
    {
        var type = notification.GetType();
        var change = type.GetProperty("Change").GetValue(notification) as System.IO.RenamedEventArgs;
        if (change == null) return;
        DirectoryPath = (string) type.GetProperty("DirectoryPath").GetValue(notification);
        OldPath = change.OldFullPath;
        NewPath = change.FullPath;
    }
}
'@
[System.Threading.SynchronizationContext]::SetSynchronizationContext(
    [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))

function Pump([int] $milliseconds) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($milliseconds)
    $timer.add_Tick({ $timer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
}

function Wait-Until([scriptblock] $condition, [string] $message) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (& $condition) -and [DateTime]::UtcNow -lt $deadline) { Pump 100 }
    if (-not (& $condition)) { throw $message }
}

function Find-TreeEntry($entries, [string] $path) {
    foreach ($entry in $entries) {
        if ($entry.Path -eq $path) { return $entry }
        $found = Find-TreeEntry $entry.Children $path
        if ($null -ne $found) { return $found }
    }
    return $null
}

    function Find-VisualChild($parent, [type] $type) {
        for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
            if ($type.IsInstanceOfType($child)) { return $child }
            $found = Find-VisualChild $child $type
            if ($null -ne $found) { return $found }
        }
        return $null
    }

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-pathview-refresh-' + [guid]::NewGuid().ToString('N'))
$siblingFile = $directory + '-sibling.txt'
$siblingDirectory = $directory + '-sibling'
$window = $null
$view = $null
try {
    [void] [IO.Directory]::CreateDirectory($directory)
    $secondFolder = Join-Path $directory 'second-folder'
    [void] [IO.Directory]::CreateDirectory($secondFolder)
    [IO.Directory]::SetLastWriteTime($secondFolder, [datetime]::Now.AddDays(-1))
    $constructor = $assembly.GetType('SUTWinExplorer.Pathview', $true).GetConstructors()[0]
    $view = $constructor.Invoke([object[]] @([string] $directory, $false, $null, $null, $null, $null))
    $content = $view.FindName('DirectoryContent')
    $content.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
    $tree = $view.FindName('ActivePathTree')
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $cache = $content.GetType().GetField('_directoryCache', $flags).GetValue($content)
    $generation = $cache.GetType().GetField('_generation', $flags)
    $snapshot = $content.GetType().GetField('_snapshot', $flags)
    $observer = $content.GetType().GetField('_directoryObserver', $flags)
    $dirty = $view.GetType().GetField('_fileSystemStateDirty', $flags)
    $dirtyDirectories = $view.GetType().GetField('_dirtyDirectories', $flags).GetValue($view)
    $tabs = [System.Windows.Controls.TabControl]::new()
    $fixed = [System.Windows.Controls.TabItem]::new()
    $fixed.Content = $view
    $other = [System.Windows.Controls.TabItem]::new()
    $other.Content = 'other'
    [void] $tabs.Items.Add($fixed)
    [void] $tabs.Items.Add($other)
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Width = 800
    $window.Height = 600
    $window.Content = $tabs
    $window.Show()
    Wait-Until { $null -ne $snapshot.GetValue($content) } 'Initial snapshot did not load.'
    Pump 500
    $initialSnapshot = $snapshot.GetValue($content)
    $initialTree = $tree.ItemsSource
    $initialGeneration = $generation.GetValue($cache)
    $initialObserver = $observer.GetValue($content)
    $initialDirty = $dirty.GetValue($view)
    if ($null -eq $initialObserver) { throw 'Directory observer was not installed.' }
    if ($initialGeneration -ne 2) { throw "Initial loading caused an extra cache invalidation: generation=$initialGeneration." }

    $tabs.SelectedItem = $other
    Pump 300
    if (-not [object]::ReferenceEquals($initialObserver, $observer.GetValue($content))) { throw 'Unloading disposed the observer.' }
    $tabs.SelectedItem = $fixed
    Pump 500
    if ($generation.GetValue($cache) -ne $initialGeneration -or
        -not [object]::ReferenceEquals($initialSnapshot, $snapshot.GetValue($content)) -or
        -not [object]::ReferenceEquals($initialTree, $tree.ItemsSource)) { throw "A clean tab was refreshed: initial dirty=$initialDirty, dirty=$($dirty.GetValue($view)), generation=$initialGeneration -> $($generation.GetValue($cache)), snapshot same=$([object]::ReferenceEquals($initialSnapshot, $snapshot.GetValue($content))), tree same=$([object]::ReferenceEquals($initialTree, $tree.ItemsSource))." }

    $currentRouteEntry = Find-TreeEntry $view.FindName('ActivePathAndSiblingsTree').ItemsSource $directory
    if ($null -eq $currentRouteEntry) { throw 'The current route entry was not found.' }
    $unchangedParentProbe = [pscustomobject] @{ Count = 0 }
    $unchangedParentHandler = [ComponentModel.PropertyChangedEventHandler] { param($sender, $eventArgs) if ($eventArgs.PropertyName -eq 'Icons') { $unchangedParentProbe.Count++ } }.GetNewClosure()
    $currentRouteEntry.add_PropertyChanged($unchangedParentHandler)
    [IO.File]::WriteAllText((Join-Path $directory 'visible.txt'), 'visible')
    Wait-Until { $dirtyDirectories.Contains($directory) } 'A visible tab did not become dirty.'
    Pump 300
    if (-not [object]::ReferenceEquals($initialSnapshot, $snapshot.GetValue($content))) { throw 'A notification refreshed the visible tab before activation.' }
    $tabs.SelectedItem = $other
    Pump 100
    $tabs.SelectedItem = $fixed
    Wait-Until { @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq (Join-Path $directory 'visible.txt') }).Count -eq 1 } 'A dirty tab did not update on activation.'
    if ($generation.GetValue($cache) -ne $initialGeneration) { throw 'A notification invalidated the directory cache.' }
    $currentRouteEntry.remove_PropertyChanged($unchangedParentHandler)
    if ($unchangedParentProbe.Count -ne 0) { throw 'A current-directory change refreshed an unchanged ancestor.' }
    if (-not @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq (Join-Path $directory 'visible.txt') }).Count) { throw 'The refreshed content omitted the new file.' }
    if (-not [object]::ReferenceEquals($initialObserver, $observer.GetValue($content))) { throw 'Refreshing replaced the observer.' }

    $tabs.SelectedItem = $other
    Pump 300
    $hiddenGeneration = $generation.GetValue($cache)
    [void] [IO.Directory]::CreateDirectory((Join-Path $directory 'hidden-folder'))
    Wait-Until { $dirtyDirectories.Contains($directory) } 'A hidden tab did not become dirty.'
    Pump 700
    if ($generation.GetValue($cache) -ne $hiddenGeneration) { throw 'A notification refreshed the hidden tab.' }
    $tabs.SelectedItem = $fixed
    Wait-Until { @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq (Join-Path $directory 'hidden-folder') }).Count -eq 1 } 'The dirty hidden tab did not update on activation.'
    if ($generation.GetValue($cache) -ne $hiddenGeneration) { throw 'A hidden-tab change invalidated the directory cache.' }
    if (-not @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq (Join-Path $directory 'hidden-folder') }).Count) { throw 'The refreshed content omitted the new directory.' }
    if (-not @($view.FindName('ActivePathSubdirectoriesList').Items | Where-Object { $_.Path -eq (Join-Path $directory 'hidden-folder') }).Count) { throw 'The refreshed tree omitted the new directory.' }

    Pump 500
    $folderPath = Join-Path $directory 'hidden-folder'
    $beforeSort = $snapshot.GetValue($content)
    $content.FindName('SortOrderEditor').Select(4)
    Wait-Until { $null -ne $snapshot.GetValue($content) -and -not [object]::ReferenceEquals($beforeSort, $snapshot.GetValue($content)) } 'Date sorting did not finish.'
    $folderRow = @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $folderPath })[0]
    Wait-Until { $null -ne $folderRow.Entry } 'The folder metadata did not load.'
    $itemList = $snapshot.GetValue($content).GetType().GetProperty('Items', $flags).GetValue($snapshot.GetValue($content))
    $folderItem = @($itemList | Where-Object { $_.GetType().GetProperty('FullPath', $flags).GetValue($_) -eq $folderPath })[0]
    $modifiedProperty = $folderItem.GetType().GetProperty('Modified', $flags)
    $oldDisplayDate = $folderRow.Entry.Modified
    $metadataGeneration = $generation.GetValue($cache)
    $cacheItemsField = $cache.GetType().GetField('_items', $flags)
    $cachedItems = $cacheItemsField.GetValue($cache)
    $enumerationDirty = $view.GetType().GetField('_enumerationDirty', $flags)
    $displayDirty = $view.GetType().GetField('_displayDirty', $flags)
    if ($null -eq $enumerationDirty -or $null -eq $displayDirty) { throw 'Explicit enumeration-dirty and display-dirty flags are missing.' }
    $tabs.SelectedItem = $other
    Pump 300
    $newDate = [datetime]::Now.AddDays(-2)
    [IO.Directory]::SetLastWriteTime($folderPath, $newDate)
    Wait-Until { $displayDirty.GetValue($view) -and [Math]::Abs(($modifiedProperty.GetValue($folderItem) - $newDate).TotalSeconds) -lt 2 } 'The changed folder metadata was not updated in the cache.'
    if ($enumerationDirty.GetValue($view) -or $generation.GetValue($cache) -ne $metadataGeneration -or $folderRow.Entry.Modified -ne $oldDisplayDate) { throw "A folder metadata change enumerated or changed the display before activation: enumerationDirty=$($enumerationDirty.GetValue($view)), generation=$metadataGeneration -> $($generation.GetValue($cache)), displayed=$oldDisplayDate -> $($folderRow.Entry.Modified)." }
    $tabs.SelectedItem = $fixed
    Wait-Until { $null -ne $snapshot.GetValue($content) -and @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $folderPath -and $null -ne $_.Entry -and [Math]::Abs(($_.Entry.Modified - $newDate).TotalSeconds) -lt 2 }).Count -eq 1 } 'The updated folder metadata was not displayed on activation.'
    if ($generation.GetValue($cache) -ne $metadataGeneration -or
        -not [object]::ReferenceEquals($cachedItems, $cacheItemsField.GetValue($cache))) { throw 'Displaying updated folder metadata enumerated its parent.' }
    $sortedPaths = @($content.FindName('FileList').Items | ForEach-Object FullPath)
    if ([Array]::IndexOf($sortedPaths, $folderPath) -ge [Array]::IndexOf($sortedPaths, $secondFolder)) { throw 'Date sorting did not use the refreshed folder metadata.' }

    $tabs.SelectedItem = $other
    Pump 300
    $nestedFile = Join-Path $folderPath 'nested.txt'
    [IO.File]::WriteAllText($nestedFile, 'nested')
    [IO.File]::AppendAllText($nestedFile, ' content')
    [IO.File]::Delete($nestedFile)
    Wait-Until { $displayDirty.GetValue($view) -and $modifiedProperty.GetValue($folderItem) -gt $newDate.AddDays(1) } 'A subdirectory change did not update its cached metadata.'
    if ($enumerationDirty.GetValue($view) -or $dirtyDirectories.Contains($directory) -or $generation.GetValue($cache) -ne $metadataGeneration) { throw 'A subdirectory change marked its parent enumeration-dirty.' }
    $tabs.SelectedItem = $fixed
    Wait-Until { -not $displayDirty.GetValue($view) -and $null -ne $snapshot.GetValue($content) -and @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $folderPath -and $null -ne $_.Entry -and $_.Entry.Modified -gt $newDate.AddDays(1) }).Count -eq 1 } 'The updated subdirectory metadata was not displayed.'
    if ($generation.GetValue($cache) -ne $metadataGeneration -or
        -not [object]::ReferenceEquals($cachedItems, $cacheItemsField.GetValue($cache))) { throw 'A subdirectory change enumerated its parent.' }

    $filePath = Join-Path $directory 'visible.txt'
    $fileRow = @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $filePath })[0]
    Wait-Until { $null -ne $fileRow.Entry } 'The file metadata did not load.'
    $itemList = $snapshot.GetValue($content).GetType().GetProperty('Items', $flags).GetValue($snapshot.GetValue($content))
    $fileItem = @($itemList | Where-Object { $_.GetType().GetProperty('FullPath', $flags).GetValue($_) -eq $filePath })[0]
    $sizeProperty = $fileItem.GetType().GetProperty('Size', $flags)
    $oldFileEntry = $fileRow.Entry
    $tabs.SelectedItem = $other
    Pump 300
    [IO.File]::AppendAllText($filePath, ' updated')
    $expectedSize = [IO.FileInfo]::new($filePath).Length
    Wait-Until { $displayDirty.GetValue($view) -and $sizeProperty.GetValue($fileItem) -eq $expectedSize } 'The changed file metadata was not updated in the cache.'
    if ($enumerationDirty.GetValue($view) -or $generation.GetValue($cache) -ne $metadataGeneration -or -not [object]::ReferenceEquals($oldFileEntry, $fileRow.Entry)) { throw 'A file metadata change enumerated or changed the display before activation.' }
    $previousSnapshot = $snapshot.GetValue($content)
    $content.FindName('NamePatternTextBox').Text = 'visible*'
    Wait-Until { $null -ne $snapshot.GetValue($content) -and -not [object]::ReferenceEquals($previousSnapshot, $snapshot.GetValue($content)) } 'Filtering the dirty view did not finish.'
    if ($generation.GetValue($cache) -ne $metadataGeneration -or -not $displayDirty.GetValue($view)) { throw 'Filtering a display-dirty view enumerated or cleared its dirty state.' }
    $previousSnapshot = $snapshot.GetValue($content)
    $content.FindName('NamePatternTextBox').Clear()
    Wait-Until { $null -ne $snapshot.GetValue($content) -and -not [object]::ReferenceEquals($previousSnapshot, $snapshot.GetValue($content)) } 'Clearing the filter did not finish.'
    $tabs.SelectedItem = $fixed
    Wait-Until { -not $displayDirty.GetValue($view) -and $null -ne $snapshot.GetValue($content) -and @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $filePath -and $null -ne $_.Entry -and -not [object]::ReferenceEquals($_.Entry, $oldFileEntry) }).Count -eq 1 } 'The changed file metadata was not displayed on activation.'
    if ($generation.GetValue($cache) -ne $metadataGeneration -or
        -not [object]::ReferenceEquals($cachedItems, $cacheItemsField.GetValue($cache))) { throw 'Displaying updated file metadata enumerated its parent.' }

    $applyingChanges = $content.GetType().GetField('_applyingFileSystemChanges', $flags)
    Wait-Until { -not $applyingChanges.GetValue($content) } 'The previous incremental update did not finish.'
    $visibleSnapshot = $snapshot.GetValue($content)
    $visibleEntry = @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $filePath })[0].Entry
    [IO.File]::AppendAllText($filePath, ' again')
    $expectedSize = [IO.FileInfo]::new($filePath).Length
    Wait-Until { $displayDirty.GetValue($view) -and $sizeProperty.GetValue($fileItem) -eq $expectedSize } 'Visible file metadata did not update in the cache.'
    Pump 300
    if (-not [object]::ReferenceEquals($visibleSnapshot, $snapshot.GetValue($content))) { throw 'A metadata notification refreshed the visible tab before activation.' }
    $tabs.SelectedItem = $other
    Pump 100
    $tabs.SelectedItem = $fixed
    Wait-Until { $sizeProperty.GetValue($fileItem) -eq $expectedSize -and -not [object]::ReferenceEquals($visibleEntry, @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $filePath })[0].Entry) } 'A visible metadata change was not displayed.'
    if ($enumerationDirty.GetValue($view) -or $generation.GetValue($cache) -ne $metadataGeneration) { throw 'A visible metadata change enumerated the directory.' }

    $overlayWait = $content.GetType().GetField('_overlayWaitCancellation', $flags)
    $refreshWait = $content.GetType().GetField('_refreshCancellation', $flags)
    $refreshTimer = $view.GetType().GetField('_fileSystemRefreshTimer', $flags).GetValue($view)
    Wait-Until { $null -ne $snapshot.GetValue($content) -and $null -eq $overlayWait.GetValue($content) -and
        $null -eq $refreshWait.GetValue($content) -and -not $applyingChanges.GetValue($content) -and
        -not $refreshTimer.IsEnabled } 'The content updates did not settle before the ancestor-change check.'
    $ancestorGeneration = $generation.GetValue($cache)
    $ancestorSnapshot = $snapshot.GetValue($content)
    $ancestorTree = $tree.ItemsSource
    $parentPath = [IO.Path]::GetDirectoryName($directory)
    $parentEntry = Find-TreeEntry $view.FindName('ActivePathAndSiblingsTree').ItemsSource $parentPath
    $routeEntry = @($parentEntry.Children | Where-Object { $_.Path -eq $directory })[0]
    if ($null -eq $routeEntry) { throw 'The route entry for the current directory was not found.' }
    $probe = [pscustomobject] @{ Count = 0 }
    $handler = [ComponentModel.PropertyChangedEventHandler] { param($sender, $eventArgs) if ($eventArgs.PropertyName -eq 'Icons') { $probe.Count++ } }.GetNewClosure()
    $routeEntry.add_PropertyChanged($handler)
    $routeEntry.RefreshIcons()
    if ($probe.Count -eq 0) { throw 'The tree-node notification probe did not fire.' }
    $probe.Count = 0
    [IO.File]::WriteAllText($siblingFile, 'unrelated')
    Pump 700
    if ($dirty.GetValue($view)) { throw 'A file in an ancestor directory marked the tab dirty.' }
    [void] [IO.Directory]::CreateDirectory($siblingDirectory)
    Wait-Until { $dirtyDirectories.Contains($parentPath) } 'An ancestor directory change did not mark the tree dirty.'
    $tabs.SelectedItem = $other
    Pump 100
    $tabs.SelectedItem = $fixed
    Wait-Until { $probe.Count -gt 0 } 'The changed ancestor tree node was not refreshed.'
    $routeEntry.remove_PropertyChanged($handler)
    if ($generation.GetValue($cache) -ne $ancestorGeneration -or
        -not [object]::ReferenceEquals($ancestorSnapshot, $snapshot.GetValue($content)) -or
        -not [object]::ReferenceEquals($ancestorTree, $tree.ItemsSource)) { throw 'An ancestor change rebuilt unrelated content or the active path tree.' }

    $notificationProbe = [DirectoryNotificationProbe]::new()
    $notificationEvent = $content.GetType().GetEvent('FileSystemChanged', $flags)
    $notificationHandler = [Delegate]::CreateDelegate($notificationEvent.EventHandlerType, $notificationProbe,
        $notificationProbe.GetType().GetMethod('OnChanged'))
    $null = $notificationEvent.GetAddMethod($true).Invoke($content, [object[]] @($notificationHandler))
    $renameGeneration = $generation.GetValue($cache)
    $renameSnapshot = $snapshot.GetValue($content)
    $oldPath = Join-Path $directory 'before-rename.txt'
    $newPath = Join-Path $directory 'after-rename.txt'
    [IO.File]::WriteAllText($oldPath, 'rename')
    [IO.File]::Move($oldPath, $newPath)
    Wait-Until { $notificationProbe.NewPath -eq $newPath } 'The rename notification was not delivered.'
    if ($notificationProbe.DirectoryPath -ne $directory -or $notificationProbe.OldPath -ne $oldPath) { throw 'The rename notification did not preserve the watched directory and old path.' }
    $tabs.SelectedItem = $other
    Pump 100
    $tabs.SelectedItem = $fixed
    Wait-Until { @($content.FindName('FileList').Items | Where-Object { $_.FullPath -eq $newPath }).Count -eq 1 } 'The renamed item was not displayed.'
    if ($generation.GetValue($cache) -ne $renameGeneration) { throw 'A rename notification invalidated the directory cache.' }
    $null = $notificationEvent.GetRemoveMethod($true).Invoke($content, [object[]] @($notificationHandler))
    $view.GetType().GetMethod('Close', $flags).Invoke($view, @())
    if ($null -ne $observer.GetValue($content)) { throw 'Closing the tab did not dispose its observer.' }
    $overlayDirectory = Join-Path $directory 'overlay-scroll-test'
    [void] [IO.Directory]::CreateDirectory($overlayDirectory)
    foreach ($index in 1..90) { [IO.File]::WriteAllText((Join-Path $overlayDirectory ('item-{0:D3}.txt' -f $index)), 'test') }
    $overlayView = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $overlayView.GetType().GetMethod('Initialize', $flags).Invoke($overlayView, [object[]] @([bool] $true))
    $overlayWindow = [System.Windows.Window]::new()
    $overlayWindow.ShowInTaskbar = $false
    $overlayWindow.Left = -20000
    $overlayWindow.Top = -20000
    $overlayWindow.Width = 800
    $overlayWindow.Height = 300
    $overlayWindow.Content = $overlayView
    try {
        $overlayWindow.Show()
        $overlayView.GetType().GetMethod('SetCurrentPath', $flags).Invoke($overlayView, [object[]] @([string] $overlayDirectory))
        $overlayView.GetType().GetMethod('Refresh', $flags).Invoke($overlayView, [object[]] @([bool] $true))
        $overlaySnapshotField = $overlayView.GetType().GetField('_snapshot', $flags)
        $overlayWaitField = $overlayView.GetType().GetField('_overlayWaitCancellation', $flags)
        Wait-Until { $null -ne $overlaySnapshotField.GetValue($overlayView) -and $null -eq $overlayWaitField.GetValue($overlayView) } 'The overlay scroll fixture did not finish loading.'
        $overlayList = $overlayView.FindName('FileList')
        $scroll = Find-VisualChild $overlayList ([System.Windows.Controls.ScrollViewer])
        if ($null -eq $scroll) { throw 'The overlay fixture has no scroll viewer.' }
        $overlayList.SelectedItems.Add($overlayList.Items[45]) | Out-Null
        $overlayList.SelectedItems.Add($overlayList.Items[46]) | Out-Null
        $overlayList.ScrollIntoView($overlayList.Items[45])
        Wait-Until { $scroll.VerticalOffset -gt 0 -and $null -ne $overlayList.Items[45].Entry } 'The selected rows did not load at a scrolled position.'
        $null = $overlayList.Focus()
        $selectedRow = $overlayList.Items[45]
        $container = $overlayList.ItemContainerGenerator.ContainerFromItem($selectedRow)
        $presenter = Find-VisualChild $container ([System.Windows.Controls.GridViewRowPresenter])
        if ($null -eq $presenter) { throw 'The selected row is not visually realized.' }
        $overlayColumnIndex = $overlayList.View.Columns.IndexOf($overlayView.FindName('ModifierIconColumn'))
        if ($overlayColumnIndex -lt 0) { throw 'The MO column is missing.' }
        $overlayCell = Find-VisualChild ([System.Windows.Media.VisualTreeHelper]::GetChild($presenter, $overlayColumnIndex)) ([System.Windows.Controls.Image])
        if ($null -eq $overlayCell) { throw 'The selected row has no visible MO image.' }
        $beforeItems = $overlayList.ItemsSource
        $beforeSnapshot = $overlaySnapshotField.GetValue($overlayView)
        $beforeOffset = $scroll.VerticalOffset
        $beforeFocus = [System.Windows.Input.Keyboard]::FocusedElement
        $overlayImage = [System.Windows.Media.DrawingImage]::new()
        $overlayImage.Freeze()
        $iconSetType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
        $icons = [Activator]::CreateInstance($iconSetType, [object[]] @($selectedRow.Entry.Icons.BaseIcon, $overlayImage, [double] 1))
        $session = $beforeSnapshot.GetType().GetProperty('IconSession', $flags).GetValue($beforeSnapshot)
        $sessionIcons = $session.GetType().GetField('_icons', $flags).GetValue($session)
        $sessionIcons[$selectedRow.FullPath] = $icons
        $completion = [Threading.Tasks.TaskCompletionSource]::new([Threading.Tasks.TaskCreationOptions]::RunContinuationsAsynchronously)
        $cancellation = [Threading.CancellationTokenSource]::new()
        $null = $overlayView.GetType().GetMethod('RefreshAfterOverlaysAsync', $flags).Invoke($overlayView,
            [object[]] @($beforeSnapshot, [string] $overlayDirectory, $completion.Task, $cancellation))
        $completion.SetResult()
        Wait-Until { [object]::ReferenceEquals($selectedRow.OverlayIcon, $overlayImage) } 'The scrolled row did not receive its overlay.'
        Wait-Until { [object]::ReferenceEquals($overlayCell.Source, $overlayImage) } 'The visible MO cell did not display the updated overlay.'
        Pump 200
        if (-not [object]::ReferenceEquals($beforeSnapshot, $overlaySnapshotField.GetValue($overlayView)) -or
            -not [object]::ReferenceEquals($beforeItems, $overlayList.ItemsSource) -or
            $scroll.VerticalOffset -ne $beforeOffset -or $overlayList.SelectedItems.Count -ne 2 -or
            -not $overlayList.SelectedItems.Contains($selectedRow) -or
            -not [object]::ReferenceEquals($beforeFocus, [System.Windows.Input.Keyboard]::FocusedElement)) {
            throw 'The overlay update changed the snapshot, rows, scroll position, selection, or focus.'
        }
    } finally {
        $overlayView.GetType().GetMethod('Close', $flags).Invoke($overlayView, @())
        $overlayWindow.Close()
    }
    $incrementalView = $constructor.Invoke([object[]] @([string] $overlayDirectory, $false, $null, $null, $null, $null))
    $incrementalWindow = [System.Windows.Window]::new()
    $incrementalWindow.ShowInTaskbar = $false
    $incrementalWindow.Left = -20000
    $incrementalWindow.Top = -20000
    $incrementalWindow.Width = 800
    $incrementalWindow.Height = 300
    $incrementalWindow.Content = $incrementalView
    try {
        $incrementalWindow.Show()
        $incrementalContent = $incrementalView.FindName('DirectoryContent')
        $incrementalList = $incrementalContent.FindName('FileList')
        $incrementalDirty = $incrementalView.GetType().GetField('_fileSystemStateDirty', $flags)
        $incrementalDisplayDirty = $incrementalView.GetType().GetField('_displayDirty', $flags)
        function Activate-Incremental {
            Wait-Until { $incrementalDirty.GetValue($incrementalView) -or $incrementalDisplayDirty.GetValue($incrementalView) } 'The filesystem notification was not recorded.'
            $incrementalView.Visibility = 'Collapsed'
            Pump 100
            $incrementalView.Visibility = 'Visible'
        }
        Wait-Until { $incrementalList.Items.Count -eq 90 } 'The incremental fixture did not load.'
        $incrementalScroll = Find-VisualChild $incrementalList ([System.Windows.Controls.ScrollViewer])
        $selectedRow = @($incrementalList.Items | Where-Object { $_.FullPath -eq (Join-Path $overlayDirectory 'item-045.txt') })[0]
        $secondSelectedRow = @($incrementalList.Items | Where-Object { $_.FullPath -eq (Join-Path $overlayDirectory 'item-046.txt') })[0]
        $unchangedRow = @($incrementalList.Items | Where-Object { $_.FullPath -eq (Join-Path $overlayDirectory 'item-080.txt') })[0]
        $incrementalList.SelectedItems.Add($selectedRow) | Out-Null
        $incrementalList.SelectedItems.Add($secondSelectedRow) | Out-Null
        $incrementalList.ScrollIntoView($selectedRow)
        Wait-Until { $incrementalScroll.VerticalOffset -gt 0 -and $null -ne $selectedRow.Entry -and $null -ne $unchangedRow.Entry } 'The incremental fixture did not load its selected rows.'
        $null = $incrementalList.Focus()
        $source = $incrementalList.ItemsSource
        $focus = [System.Windows.Input.Keyboard]::FocusedElement
        $offset = $incrementalScroll.VerticalOffset
        $events = [System.Collections.Generic.List[string]]::new()
        $collectionHandler = [System.Collections.Specialized.NotifyCollectionChangedEventHandler] { param($sender, $eventArgs) $events.Add($eventArgs.Action.ToString()) }.GetNewClosure()
        $source.add_CollectionChanged($collectionHandler)

        $oldEntry = $unchangedRow.Entry
        $selectedEntry = $selectedRow.Entry
        [IO.File]::AppendAllText($unchangedRow.FullPath, ' changed')
        Activate-Incremental
        Wait-Until { -not [object]::ReferenceEquals($oldEntry, $unchangedRow.Entry) } 'The changed row was not updated.'
        if ($events.Count -ne 0 -or -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource) -or
            -not [object]::ReferenceEquals($selectedRow, $incrementalList.SelectedItems[0]) -or
            -not [object]::ReferenceEquals($selectedEntry, $selectedRow.Entry) -or
            $incrementalList.SelectedItems.Count -ne 2 -or $incrementalScroll.VerticalOffset -ne $offset -or
            -not [object]::ReferenceEquals($focus, [System.Windows.Input.Keyboard]::FocusedElement)) { throw 'A metadata change disturbed unrelated rows or UI state.' }

        $addedPath = Join-Path $overlayDirectory 'zzzz-added.txt'
        [IO.File]::WriteAllText($addedPath, 'new')
        Activate-Incremental
        Wait-Until { @($incrementalList.Items | Where-Object { $_.FullPath -eq $addedPath }).Count -eq 1 } 'An external addition was not displayed.'
        [IO.File]::Delete($addedPath)
        Activate-Incremental
        Wait-Until { @($incrementalList.Items | Where-Object { $_.FullPath -eq $addedPath }).Count -eq 0 } 'An external deletion was not displayed.'
        if ($events.Contains('Reset') -or -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource) -or
            -not $incrementalList.SelectedItems.Contains($selectedRow) -or -not $incrementalList.SelectedItems.Contains($secondSelectedRow) -or
            $incrementalScroll.VerticalOffset -ne $offset) { throw 'An addition or deletion disturbed unrelated rows or UI state.' }

        $renamedPath = Join-Path $overlayDirectory 'item-045-renamed.txt'
        [IO.File]::Move($selectedRow.FullPath, $renamedPath)
        Activate-Incremental
        Wait-Until { $selectedRow.FullPath -eq $renamedPath -and $null -ne $selectedRow.Entry -and $selectedRow.Entry.FullPath -eq $renamedPath } 'The selected external rename did not update its existing row.'
        if (-not $incrementalList.SelectedItems.Contains($selectedRow) -or -not $incrementalList.SelectedItems.Contains($secondSelectedRow) -or
            -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource) -or $events.Contains('Reset') -or
            $incrementalScroll.VerticalOffset -ne $offset) { throw 'An external rename lost selection or rebuilt the list.' }

        $container = $incrementalList.ItemContainerGenerator.ContainerFromItem($selectedRow)
        $anchorY = $container.TranslatePoint([System.Windows.Point]::new(0, 0), $incrementalScroll).Y
        $beforePath = Join-Path $overlayDirectory 'item-001a.txt'
        [IO.File]::WriteAllText($beforePath, 'new')
        Activate-Incremental
        Wait-Until { @($incrementalList.Items | Where-Object { $_.FullPath -eq $beforePath }).Count -eq 1 } 'An insertion before the viewport was not displayed.'
        $incrementalList.UpdateLayout()
        $container = $incrementalList.ItemContainerGenerator.ContainerFromItem($selectedRow)
        if ($null -eq $container -or [Math]::Abs($container.TranslatePoint([System.Windows.Point]::new(0, 0), $incrementalScroll).Y - $anchorY) -gt 1) { throw 'An insertion before the viewport moved the visible anchor.' }
        [IO.File]::Delete($beforePath)
        Activate-Incremental
        Wait-Until { @($incrementalList.Items | Where-Object { $_.FullPath -eq $beforePath }).Count -eq 0 } 'A deletion before the viewport was not displayed.'
        $incrementalList.UpdateLayout()
        $container = $incrementalList.ItemContainerGenerator.ContainerFromItem($selectedRow)
        if ($null -eq $container -or [Math]::Abs($container.TranslatePoint([System.Windows.Point]::new(0, 0), $incrementalScroll).Y - $anchorY) -gt 1) { throw 'A deletion before the viewport moved the visible anchor.' }

        $otherAnchor = $incrementalList.Items[[int][Math]::Floor($incrementalScroll.VerticalOffset)]
        $container = $incrementalList.ItemContainerGenerator.ContainerFromItem($otherAnchor)
        $anchorY = $container.TranslatePoint([System.Windows.Point]::new(0, 0), $incrementalScroll).Y
        $movedPath = Join-Path $overlayDirectory 'item-070-renamed.txt'
        [IO.File]::Move($selectedRow.FullPath, $movedPath)
        Activate-Incremental
        Wait-Until { $selectedRow.FullPath -eq $movedPath -and $null -ne $selectedRow.Entry } 'A rename that changes sort order did not finish.'
        $incrementalList.UpdateLayout()
        $container = $incrementalList.ItemContainerGenerator.ContainerFromItem($otherAnchor)
        if ($null -eq $container -or [Math]::Abs($container.TranslatePoint([System.Windows.Point]::new(0, 0), $incrementalScroll).Y - $anchorY) -gt 1 -or
            -not $incrementalList.SelectedItems.Contains($selectedRow) -or -not $incrementalList.SelectedItems.Contains($secondSelectedRow) -or
            -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource) -or $events.Contains('Reset')) { throw "A sorted rename disturbed the visible anchor, selection, or row collection: anchor=$anchorY -> $(if ($container) { $container.TranslatePoint([System.Windows.Point]::new(0, 0), $incrementalScroll).Y } else { 'missing' }), selected=$($incrementalList.SelectedItems.Contains($selectedRow)), second=$($incrementalList.SelectedItems.Contains($secondSelectedRow)), source=$([object]::ReferenceEquals($source, $incrementalList.ItemsSource)), events=$($events -join ',')." }
        $names = @($incrementalList.Items | ForEach-Object { [IO.Path]::GetFileName($_.FullPath) })
        if ([Array]::IndexOf($names, 'item-069.txt') -ge [Array]::IndexOf($names, 'item-070-renamed.txt') -or
            [Array]::IndexOf($names, 'item-070-renamed.txt') -ge [Array]::IndexOf($names, 'item-071.txt')) { throw 'The renamed row was not moved into sorted order.' }

        $intermediatePath = Join-Path $overlayDirectory 'intermediate-name.txt'
        $finalPath = Join-Path $overlayDirectory 'final-name.txt'
        [IO.File]::Move($selectedRow.FullPath, $intermediatePath)
        [IO.File]::Move($intermediatePath, $finalPath)
        Activate-Incremental
        Wait-Until { $selectedRow.FullPath -eq $finalPath -and $null -ne $selectedRow.Entry } 'A batch of external renames lost the original row.'
        if (-not $incrementalList.SelectedItems.Contains($selectedRow) -or -not $incrementalList.SelectedItems.Contains($secondSelectedRow)) { throw 'A batch of external renames lost selection.' }

        $casePath = Join-Path $overlayDirectory 'FINAL-NAME.txt'
        [IO.File]::Move($finalPath, $casePath)
        Activate-Incremental
        Wait-Until { $selectedRow.FullPath -ceq $casePath -and $null -ne $selectedRow.Entry -and $selectedRow.Entry.FullPath -ceq $casePath } 'A case-only rename did not update the existing row.'
        if (-not $incrementalList.SelectedItems.Contains($selectedRow)) { throw 'A case-only rename lost selection.' }

        [IO.File]::Delete($casePath)
        Activate-Incremental
        Wait-Until { -not $incrementalList.Items.Contains($selectedRow) } 'The deleted selected row remained in the list.'
        if ($incrementalList.SelectedItems.Count -ne 1 -or -not $incrementalList.SelectedItems.Contains($secondSelectedRow) -or
            -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource) -or $events.Contains('Reset')) { throw 'Deleting a selected item disturbed the remaining selection or rebuilt the list.' }
        $source.remove_CollectionChanged($collectionHandler)

        $incrementalContent.FindName('NamePatternTextBox').Text = 'item*'
        Wait-Until { $null -ne $incrementalContent.GetType().GetField('_snapshot', $flags).GetValue($incrementalContent) -and
            -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource) } 'The name filter did not finish.'
        $source = $incrementalList.ItemsSource
        $filteredRow = @($incrementalList.Items | Where-Object { $_.FullPath -eq (Join-Path $overlayDirectory 'item-046.txt') })[0]
        $incrementalList.SelectedItem = $filteredRow
        $outsideFilter = Join-Path $overlayDirectory 'outside-filter.txt'
        [IO.File]::Move($filteredRow.FullPath, $outsideFilter)
        Activate-Incremental
        Wait-Until { -not $incrementalList.Items.Contains($filteredRow) } 'A rename outside the active filter did not remove the row.'
        if ($incrementalList.SelectedItems.Count -ne 0 -or -not [object]::ReferenceEquals($source, $incrementalList.ItemsSource)) { throw 'A filtered rename retained a missing selection or replaced the list.' }
        $insideFilter = Join-Path $overlayDirectory 'item-returned.txt'
        [IO.File]::Move($outsideFilter, $insideFilter)
        Activate-Incremental
        Wait-Until { @($incrementalList.Items | Where-Object { $_.FullPath -eq $insideFilter }).Count -eq 1 } 'A rename into the active filter did not add the row.'
        if (-not [object]::ReferenceEquals($source, $incrementalList.ItemsSource)) { throw 'A rename into the filter replaced the list.' }

        $incrementalCache = $incrementalContent.GetType().GetField('_directoryCache', $flags).GetValue($incrementalContent)
        $incrementalGeneration = $incrementalCache.GetType().GetField('_generation', $flags)
        $beforeFallback = $incrementalGeneration.GetValue($incrementalCache)
        $notificationType = $assembly.GetType('SUTWinExplorer.DirectoryNotification', $true)
        $unknownNotification = $notificationType.GetConstructors([Reflection.BindingFlags]'Instance,Public,NonPublic')[0].Invoke([object[]] @([string] $overlayDirectory, $null))
        $incrementalView.GetType().GetMethod('ContentView_FileSystemChanged', $flags).Invoke($incrementalView, [object[]] @($incrementalContent, $unknownNotification))
        Activate-Incremental
        Wait-Until { $incrementalGeneration.GetValue($incrementalCache) -gt $beforeFallback -and
            $null -ne $incrementalContent.GetType().GetField('_snapshot', $flags).GetValue($incrementalContent) } 'An unknown notification did not trigger a full refresh.'
    } finally {
        $incrementalView.GetType().GetMethod('Close', $flags).Invoke($incrementalView, @())
        $incrementalWindow.Close()
    }
    Write-Output 'Pathview refresh lifecycle passed.'
} finally {
    if ($null -ne $view) { $view.GetType().GetMethod('Close', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($view, @()) }
    if ($null -ne $window) { $window.Close() }
    $application.Shutdown()
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
    if ([IO.File]::Exists($siblingFile)) { [IO.File]::Delete($siblingFile) }
    if ([IO.Directory]::Exists($siblingDirectory)) { [IO.Directory]::Delete($siblingDirectory, $true) }
}