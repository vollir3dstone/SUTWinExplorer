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
    Pump 700
    if ($generation.GetValue($cache) -ne $initialGeneration -or
        -not [object]::ReferenceEquals($initialSnapshot, $snapshot.GetValue($content))) { throw 'A notification refreshed the visible tab.' }
    $tabs.SelectedItem = $other
    Pump 300
    $tabs.SelectedItem = $fixed
    Wait-Until { $generation.GetValue($cache) -gt $initialGeneration -and $null -ne $snapshot.GetValue($content) } 'The dirty visible tab did not refresh on activation.'
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
    Wait-Until { $generation.GetValue($cache) -gt $hiddenGeneration -and $null -ne $snapshot.GetValue($content) } 'The dirty hidden tab did not refresh on activation.'
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

    $visibleSnapshot = $snapshot.GetValue($content)
    [IO.File]::AppendAllText($filePath, ' again')
    $expectedSize = [IO.FileInfo]::new($filePath).Length
    Wait-Until { $displayDirty.GetValue($view) -and $sizeProperty.GetValue($fileItem) -eq $expectedSize } 'Visible file metadata did not update in the cache.'
    Pump 500
    if ($enumerationDirty.GetValue($view) -or $generation.GetValue($cache) -ne $metadataGeneration -or
        -not [object]::ReferenceEquals($visibleSnapshot, $snapshot.GetValue($content))) { throw 'A visible metadata change refreshed the display or enumerated.' }
    $tabs.SelectedItem = $other
    Pump 300
    $tabs.SelectedItem = $fixed
    Wait-Until { -not $displayDirty.GetValue($view) -and $null -ne $snapshot.GetValue($content) -and -not [object]::ReferenceEquals($visibleSnapshot, $snapshot.GetValue($content)) } 'The visible metadata change was not displayed after reactivation.'
    if ($generation.GetValue($cache) -ne $metadataGeneration) { throw 'Reactivating a display-dirty tab enumerated.' }

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
    Pump 700
    $tabs.SelectedItem = $other
    Pump 300
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
    Pump 500
    if ($generation.GetValue($cache) -ne $renameGeneration -or
        -not [object]::ReferenceEquals($renameSnapshot, $snapshot.GetValue($content))) { throw 'A rename notification refreshed the visible directory.' }
    $null = $notificationEvent.GetRemoveMethod($true).Invoke($content, [object[]] @($notificationHandler))
    $view.GetType().GetMethod('Close', $flags).Invoke($view, @())
    if ($null -ne $observer.GetValue($content)) { throw 'Closing the tab did not dispose its observer.' }
    Write-Output 'Pathview refresh lifecycle passed.'
} finally {
    if ($null -ne $view) { $view.GetType().GetMethod('Close', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($view, @()) }
    if ($null -ne $window) { $window.Close() }
    $application.Shutdown()
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
    if ([IO.File]::Exists($siblingFile)) { [IO.File]::Delete($siblingFile) }
    if ([IO.Directory]::Exists($siblingDirectory)) { [IO.Directory]::Delete($siblingDirectory, $true) }
}