$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public static class IconCacheConcurrencyProbe
{
    public static void Run(object cache, object bitmap, string directory)
    {
        var type = cache.GetType();
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var store = type.GetMethod("Store", flags);
        var find = type.GetMethod("Find", flags);
        var save = type.GetMethod("Save", flags);
        System.Threading.Tasks.Parallel.For(0, 40, index =>
        {
            var path = System.IO.Path.Combine(directory, "parallel", index.ToString());
            store.Invoke(cache, new object[] { path, "small", 16, 16, bitmap, index % 2 == 0, index });
            if (find.Invoke(cache, new object[] { path, "small", 16, 16 }) == null)
                throw new System.InvalidOperationException("Concurrent lookup failed.");
            if (index % 10 == 0) save.Invoke(cache, new object[0]);
        });
    }
}

public sealed class IconCacheRootProbe
{
    public readonly System.Collections.Generic.List<string> Roots = new();
    public void OnRootAdded(string root) { lock (Roots) Roots.Add(root); }
}
'@

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$cacheType = $assembly.GetType('SUTWinExplorer.IconCache', $true)
$flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$constructor = $cacheType.GetConstructor($flags, $null, [type[]] @([string]), $null)
$find = $cacheType.GetMethod('Find', $flags)
$store = $cacheType.GetMethod('Store', $flags)
$load = $cacheType.GetMethod('Load', $flags)
$save = $cacheType.GetMethod('Save', $flags)
$getRoots = $cacheType.GetMethod('GetFileSystemRoots', $flags)
$getItems = $cacheType.GetMethod('GetFileSystemItems', $flags)
$getItem = $cacheType.GetMethod('GetFileSystemItem', $flags)
$rootEvent = $cacheType.GetEvent('FileSystemRootAdded', $flags)
function Find-Icon($cache, [string] $path, [string] $variant, [int] $width, [int] $height) {
    return $find.Invoke($cache, [object[]] @([string] $path, [string] $variant, [int] $width, [int] $height))
}
function Store-Icon($cache, [string] $path, [string] $variant, [int] $width, [int] $height, $bitmap, [bool] $hasOverlay, $baseIconIndex = $null) {
    $store.Invoke($cache, [object[]] @([string] $path, [string] $variant, [int] $width, [int] $height, $bitmap, [bool] $hasOverlay, $baseIconIndex))
}
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-icon-cache-test-' + [guid]::NewGuid().ToString('N'))
$filePath = Join-Path $directory 'cache.json'
$first = Join-Path $directory 'Folder\first.txt'
$second = Join-Path $directory 'Folder\second.txt'
$third = Join-Path $directory 'Folder\third.txt'

try {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $pixels = [byte[]] @(0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255)
    $bitmap = [System.Windows.Media.Imaging.BitmapSource]::Create(2, 2, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null, $pixels, 8)
    $bitmap.Freeze()
    $cache = $constructor.Invoke([object[]] @([string] $filePath))
    $load.Invoke($cache, @())
    $rootProbe = [IconCacheRootProbe]::new()
    $rootHandler = [Delegate]::CreateDelegate($rootEvent.EventHandlerType, $rootProbe, $rootProbe.GetType().GetMethod('OnRootAdded'))
    $rootEvent.GetAddMethod($true).Invoke($cache, [object[]] @($rootHandler))
    Assert-True ($null -eq (Find-Icon $cache $first 'small' 16 16)) 'Missing path unexpectedly found.'
    Store-Icon $cache $first 'small' 16 16 $bitmap $false ([int] 101)
    Store-Icon $cache $second 'small' 16 16 $bitmap $false ([int] 202)
    Store-Icon $cache $third 'small' 16 16 $bitmap $true
    Store-Icon $cache $first 'sized' 32 32 $bitmap $false
    Store-Icon $cache 'Z:\other\item.txt' 'small' 16 16 $bitmap $false
    Assert-True ($rootProbe.Roots.Count -eq 2 -and $rootProbe.Roots.Contains([IO.Path]::GetPathRoot($directory)) -and $rootProbe.Roots.Contains('Z:\')) 'New filesystem roots were not reported exactly once.'
    $roots = @($getRoots.Invoke($cache, @()))
    Assert-True ($roots.Count -eq 2 -and $roots -contains 'Z:\') 'Filesystem roots were not enumerated.'
    $cachedItem = $getItem.Invoke($cache, [object[]] @([string] $first.ToUpperInvariant()))
    Assert-True ($null -ne $cachedItem -and $cachedItem.Variants.Count -eq 2 -and @($cachedItem.Variants | Where-Object { $_.Name -eq 'sized' -and $_.Width -eq 32 -and $_.Height -eq 32 }).Count -eq 1) 'Cached item variants were not enumerated.'
    Assert-True (@($getItems.Invoke($cache, @()) | Where-Object { $_.Path -eq $first }).Count -eq 1) 'Cached filesystem item paths were not enumerated.'
    $deep = $directory
    foreach ($number in 1..40) { $deep = Join-Path $deep "level$number" }
    Store-Icon $cache $deep 'small' 16 16 $bitmap $false
    [IconCacheConcurrencyProbe]::Run($cache, $bitmap, $directory)
    $save.Invoke($cache, @())
    Assert-True (Test-Path -LiteralPath $filePath) 'Cache was not saved.'
    $json = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json -AsHashtable -Depth 200
    Assert-True ($json._type -eq 'IconCache' -and $json.Version -eq 1) 'Incorrect cache header.'
    Assert-True ($json.Images.Count -eq 2) 'Equal bitmaps were not deduplicated by overlay flag.'
    Assert-True (@($json.Images.Values | Where-Object HasOverlay).Count -eq 1) 'Overlay flag not stored with image ID.'

    $restored = $constructor.Invoke([object[]] @([string] $filePath))
    $load.Invoke($restored, @())
    $found = Find-Icon $restored $first.ToUpperInvariant() 'small' 16 16
    Assert-True ($null -ne $found -and -not $found.HasOverlay -and $found.Image.IsFrozen) 'Case-insensitive round trip failed.'
    Assert-True ($found.BaseIconIndex -eq 101 -and (Find-Icon $restored $second 'small' 16 16).BaseIconIndex -eq 202) 'Per-path Windows icon indices did not round-trip.'
    Assert-True ((Find-Icon $restored $third 'small' 16 16).HasOverlay) 'Overlay flag was lost.'
    Assert-True ($null -ne (Find-Icon $restored $first 'sized' 32 32)) 'Size variant was lost.'
    Assert-True ($null -eq (Find-Icon $restored $first 'small' 32 32)) 'Different image variants collided.'
    Assert-True ($null -ne (Find-Icon $restored $deep 'small' 16 16)) 'Deep tree did not round-trip.'
    Assert-True ($null -ne (Find-Icon $restored (Join-Path $directory 'parallel\39') 'small' 16 16)) 'Concurrent updates did not round-trip.'
    Assert-True ($null -eq (Find-Icon $restored ($second + '-other') 'small' 16 16)) 'Distinct paths collided.'

    [System.IO.File]::WriteAllText($filePath, '{invalid')
    $broken = $constructor.Invoke([object[]] @([string] $filePath))
    $load.Invoke($broken, @())
    Assert-True ($null -eq (Find-Icon $broken $first 'small' 16 16)) 'Malformed cache did not fall back to empty.'
    [System.IO.File]::WriteAllText($filePath, '{"_type":"IconCache","Version":999,"Roots":{},"Images":{}}')
    $load.Invoke($broken, @())
    Assert-True ($null -eq (Find-Icon $broken $first 'small' 16 16)) 'Unsupported cache version was accepted.'
    [System.IO.File]::WriteAllText($filePath, '{}')
    $load.Invoke($broken, @())
    Assert-True ($null -eq (Find-Icon $broken $first 'small' 16 16)) 'Incomplete cache was accepted.'
    [System.IO.File]::WriteAllText($filePath, '{"_type":"IconCache","Version":1,"Roots":{},"Images":{"bad":{"Width":1,"Height":1,"Png":"YWJj","HasOverlay":false}}}')
    $load.Invoke($broken, @())
    Assert-True ($null -eq (Find-Icon $broken $first 'small' 16 16)) 'Invalid image did not fall back to empty.'
    $previous = [System.IO.File]::ReadAllText($filePath)
    $locked = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try { $save.Invoke($cache, @()) } finally { $locked.Dispose() }
    Assert-True ([System.IO.File]::ReadAllText($filePath) -ceq $previous) 'Failed save damaged the existing cache file.'

    $provider = $assembly.GetType('SUTWinExplorer.ShellIconProvider', $true)
    $staticFlags = [System.Reflection.BindingFlags]'Static,NonPublic'
    $initialize = $provider.GetMethod('InitializeCache', $staticFlags)
    $saveProvider = $provider.GetMethod('SaveCache', $staticFlags)
    $getSmall = $provider.GetMethod('GetSmallIcons')
    $getSized = $provider.GetMethod('GetIconAtSize')
    $shellPath = Join-Path $directory 'sample.txt'
    [System.IO.File]::WriteAllText($shellPath, 'sample')
    $initialize.Invoke($null, [object[]] @([string] $filePath))
    $shellIcon = $getSmall.Invoke($null, [object[]] @([string] $shellPath))
    Assert-True ($null -ne $shellIcon.BaseIcon) 'Shell did not return the test icon.'
    $providerCache = $provider.GetField('_cache', $staticFlags).GetValue($null)
    $cached = Find-Icon $providerCache $shellPath 'small' 16 16
    Assert-True ($null -ne $cached) 'Shell icon was not inserted into the shared cache.'
    if (-not $cached.HasOverlay) {
        Store-Icon $providerCache $shellPath 'small' 16 16 $cached.Image $true
        $refreshed = $getSmall.Invoke($null, [object[]] @([string] $shellPath))
        $iconSetType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
        Assert-True ($iconSetType.GetProperty('OverlayKnown', $flags).GetValue($refreshed) -and
            $iconSetType.GetProperty('OverlaySlot', $flags).GetValue($refreshed) -eq 0) 'Known overlay was not queried again.'
        $itemType = $assembly.GetType('SUTWinExplorer.DirectoryItem', $true)
        $item = [Activator]::CreateInstance($itemType, [object[]] @([string] 'sample.txt', [string] $shellPath, [bool] $false, [bool] $false))
        $entryProperty = $itemType.GetProperty('Entry', $flags)
        $firstEntry = $entryProperty.GetValue($item)
        $secondEntry = $entryProperty.GetValue($item)
        Assert-True ([object]::ReferenceEquals($firstEntry, $secondEntry)) 'Reused entry should not synchronously requery its overlay.'
        Store-Icon $providerCache $shellPath 'small' 16 16 $cached.Image $false
    }
    $visitDirectory = Join-Path $directory 'first-visit'
    [IO.Directory]::CreateDirectory($visitDirectory) | Out-Null
    $visitPath = Join-Path $visitDirectory 'visit.txt'
    [IO.File]::WriteAllText($visitPath, 'visit')
    Store-Icon $providerCache $visitPath 'small' 16 16 $bitmap $true ([int] 999999)
    $shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
    $open = $shell.GetMethod('OpenCachedDirectoryAsync', $staticFlags)
    $directoryCacheType = $assembly.GetType('SUTWinExplorer.DirectoryDataCache', $true)
    $sortType = $assembly.GetType('SUTWinExplorer.DirectorySortState', $true)
    $directoryCache = [Activator]::CreateInstance($directoryCacheType, $true)
    $otherDirectoryCache = [Activator]::CreateInstance($directoryCacheType, $true)
    $sorting = [Activator]::CreateInstance($sortType, $true)
    $firstVisit = $open.Invoke($null, [object[]] @([string] $visitDirectory, [bool] $true, [bool] $false, [string] '', $sorting, $directoryCache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    $completionProperty = $firstVisit.GetType().GetProperty('OverlayCompletion', $flags)
    $completion = $completionProperty.GetValue($firstVisit)
    Assert-True ($null -ne $completion -and (Find-Icon $providerCache $visitPath 'small' 16 16).BaseIconIndex -ne 999999) 'First visit did not replace the stale base icon and schedule overlays.'
    $completion.GetAwaiter().GetResult()
    $firstVersion = @($getItem.Invoke($providerCache, [object[]] @([string] $visitPath)).Variants | Where-Object Name -eq 'small')[0].Version
    $secondVisit = $open.Invoke($null, [object[]] @([string] $visitDirectory.ToUpperInvariant(), [bool] $true, [bool] $false, [string] '', $sorting, $otherDirectoryCache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    $secondVersion = @($getItem.Invoke($providerCache, [object[]] @([string] $visitPath)).Variants | Where-Object Name -eq 'small')[0].Version
    Assert-True ($null -eq $completionProperty.GetValue($secondVisit) -and $firstVersion -eq $secondVersion) 'A second view refreshed an already visited directory.'
    $getRange = $shell.GetMethod('GetDirectoryRangeAsync', $staticFlags)
    $visitEntry = @($getRange.Invoke($null, [object[]] @($secondVisit, [int] 0, [int] 1, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())[0]
    $visitIcon = $visitEntry.Icons
    $iconSetType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
    $overlayKnown = $iconSetType.GetProperty('OverlayKnown', $flags).GetValue($visitIcon)
    $overlaySlot = $iconSetType.GetProperty('OverlaySlot', $flags).GetValue($visitIcon)
    Assert-True ($overlayKnown -and (Find-Icon $providerCache $visitPath 'small' 16 16).HasOverlay -eq ($overlaySlot -gt 0)) 'The completed overlay was not propagated to the cache and the second view.'
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $viewSort = $view.GetType().GetField('_sorting', $flags).GetValue($view)
    $sortPairs = $viewSort.GetType().GetProperty('Pairs', $flags).GetValue($viewSort)
    Assert-True (@($sortPairs | Where-Object { $_.Column.ToString() -eq 'Overlay' }).Count -eq 0 -and
        $view.FindName('FileList').View.Columns[2].Header.Tag -eq $null) 'MO remains available in the sort widget or header.'
    $setDirectories = $shell.GetMethod('SetOverlayDirectories', $staticFlags)
    $null = $setDirectories.Invoke($null, [object[]] @([string[]] @(), $null))
    $priorityPaths = @('active', 'visited', 'unvisited', 'left') | ForEach-Object {
        $path = Join-Path $directory ("priority-" + $_)
        [IO.Directory]::CreateDirectory($path) | Out-Null
        foreach ($index in 1..30) { [IO.File]::WriteAllText((Join-Path $path "item-$index.txt"), 'test') }
        [string] $path
    }
    $priorityTasks = @()
    foreach ($path in $priorityPaths) {
        $priorityCache = [Activator]::CreateInstance($directoryCacheType, $true)
        $snapshot = $open.Invoke($null, [object[]] @([string] $path, [bool] $true, [bool] $false, [string] '', $sorting, $priorityCache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        $priorityTasks += $completionProperty.GetValue($snapshot)
    }
    Assert-True (@($priorityTasks | Where-Object { $null -eq $_ -or $_.IsCompleted }).Count -eq 0) 'Overlay work started before an active directory was selected.'
    $waitingPath = Join-Path $directory 'priority-not-yet-prepared'
    $null = $setDirectories.Invoke($null, [object[]] @([string[]] @($waitingPath, $priorityPaths[1]), [string] $waitingPath))
    [Threading.Tasks.Task]::Delay(200).GetAwaiter().GetResult()
    Assert-True (@($priorityTasks | Where-Object IsCompleted).Count -eq 0) 'An inactive directory ran before the active directory was prepared.'
    $null = $setDirectories.Invoke($null, [object[]] @([string[]] @($priorityPaths[0], $priorityPaths[1], $priorityPaths[2]), [string] $priorityPaths[0]))
    $firstCompleted = [Threading.Tasks.Task]::WhenAny([Threading.Tasks.Task[]] $priorityTasks).GetAwaiter().GetResult()
    Assert-True ([object]::ReferenceEquals($firstCompleted, $priorityTasks[0])) 'The active directory did not finish first.'
    $secondCompleted = [Threading.Tasks.Task]::WhenAny([Threading.Tasks.Task[]] @($priorityTasks[1], $priorityTasks[2], $priorityTasks[3])).GetAwaiter().GetResult()
    Assert-True ([object]::ReferenceEquals($secondCompleted, $priorityTasks[1])) 'A previously visited tab did not finish before unvisited and left tabs.'
    $thirdCompleted = [Threading.Tasks.Task]::WhenAny([Threading.Tasks.Task[]] @($priorityTasks[2], $priorityTasks[3])).GetAwaiter().GetResult()
    Assert-True ([object]::ReferenceEquals($thirdCompleted, $priorityTasks[2])) 'A left directory finished before an unvisited open tab.'
    Assert-True ($priorityTasks[3].Wait([TimeSpan]::FromSeconds(30))) 'A left directory did not finish after open tabs.'
    $null = $setDirectories.Invoke($null, [object[]] @([string[]] @(), $null))
    $switchPaths = @('before-switch', 'after-switch') | ForEach-Object {
        $path = Join-Path $directory ("priority-" + $_)
        [IO.Directory]::CreateDirectory($path) | Out-Null
        foreach ($index in 1..60) { [IO.File]::WriteAllText((Join-Path $path "item-$index.txt"), 'test') }
        [string] $path
    }
    $switchTasks = @()
    foreach ($path in $switchPaths) {
        $priorityCache = [Activator]::CreateInstance($directoryCacheType, $true)
        $snapshot = $open.Invoke($null, [object[]] @([string] $path, [bool] $true, [bool] $false, [string] '', $sorting, $priorityCache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        $switchTasks += $completionProperty.GetValue($snapshot)
    }
    $sessions = $shell.GetField('DirectoryIcons', $staticFlags).GetValue($null)
    $session = $sessions[[string] $switchPaths[0]]
    $queue = $session.GetType().GetField('_pending', $flags).GetValue($session)
    $null = $setDirectories.Invoke($null, [object[]] @([string[]] $switchPaths, [string] $switchPaths[0]))
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($queue.Count -eq 60 -and [DateTime]::UtcNow -lt $deadline) { [Threading.Tasks.Task]::Delay(10).GetAwaiter().GetResult() }
    Assert-True ($queue.Count -lt 60 -and -not $switchTasks[0].IsCompleted) 'Could not observe the original active tab processing.'
    $null = $setDirectories.Invoke($null, [object[]] @([string[]] $switchPaths, [string] $switchPaths[1]))
    $switchCompleted = [Threading.Tasks.Task]::WhenAny([Threading.Tasks.Task[]] $switchTasks).GetAwaiter().GetResult()
    Assert-True ([object]::ReferenceEquals($switchCompleted, $switchTasks[1])) 'Tab switching did not prioritize the newly active directory.'
    Assert-True ($switchTasks[0].Wait([TimeSpan]::FromSeconds(30))) 'The previously active directory did not resume.'
    $sized = $getSized.Invoke($null, [object[]] @([string] $shellPath, [int] 32, [int] 32))
    Assert-True ($null -ne $sized -and $null -ne (Find-Icon $providerCache $shellPath 'sized' 32 32)) 'Size-specific Shell icon was not cached.'
    $prepareRefresh = $provider.GetMethod('PrepareCachedItemRefresh', $staticFlags)
    Store-Icon $providerCache $shellPath 'small' 16 16 $bitmap $false ([int] 999999)
    Store-Icon $providerCache $shellPath 'sized' 32 32 $bitmap $false
    $refresh = $prepareRefresh.Invoke($null, [object[]] @($providerCache, [string] $shellPath))
    Assert-True ($null -ne $refresh) 'A cached filesystem item did not prepare a refresh.'
    $refresh.Invoke()
    $refreshedSmall = Find-Icon $providerCache $shellPath 'small' 16 16
    $refreshedSized = Find-Icon $providerCache $shellPath 'sized' 32 32
    Assert-True ($null -ne $refreshedSmall -and $refreshedSmall.Image.PixelWidth -eq 16 -and $refreshedSmall.BaseIconIndex -ne 999999) 'Small icon and index were not refreshed from the Shell.'
    Assert-True ($null -ne $refreshedSized -and $refreshedSized.Image.PixelWidth -gt 2) 'Sized icon was not refreshed from the Shell.'
    $staleRefresh = $prepareRefresh.Invoke($null, [object[]] @($providerCache, [string] $shellPath))
    Store-Icon $providerCache $shellPath 'small' 16 16 $refreshedSmall.Image $refreshedSmall.HasOverlay ([int] 999998)
    $staleRefresh.Invoke()
    Assert-True ((Find-Icon $providerCache $shellPath 'small' 16 16).BaseIconIndex -eq 999998) 'An older refresh overwrote a newer cached variant.'
    $refresh = $prepareRefresh.Invoke($null, [object[]] @($providerCache, [string] $shellPath))
    $refresh.Invoke()
    $missingPath = Join-Path $directory 'missing.txt'
    Store-Icon $providerCache $missingPath 'small' 16 16 $bitmap $false ([int] 10)
    $missingRefresh = $prepareRefresh.Invoke($null, [object[]] @($providerCache, [string] $missingPath))
    $missingRefresh.Invoke()
    Assert-True ($null -eq (Find-Icon $providerCache $missingPath 'small' 16 16)) 'An unavailable item retained a stale cached icon.'
    $saveProvider.Invoke($null, @())
    $initialize.Invoke($null, [object[]] @([string] $filePath))
    $providerCache = $provider.GetField('_cache', $staticFlags).GetValue($null)
    Assert-True ($null -ne (Find-Icon $providerCache $shellPath 'small' 16 16)) 'Provider did not reload the icon.'
    $sortDirectory = Join-Path $directory 'sorting'
    [System.IO.Directory]::CreateDirectory($sortDirectory) | Out-Null
    foreach ($name in @('first.txt', 'second.exe', 'third.png')) {
        $path = Join-Path $sortDirectory $name
        [System.IO.File]::WriteAllText($path, 'sample')
    }
    $shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
    $openSorted = $shell.GetMethod('OpenSortedDirectoryAsync', $staticFlags)
    $sortType = $assembly.GetType('SUTWinExplorer.DirectorySortState', $true)
    $pairType = $assembly.GetType('SUTWinExplorer.DirectorySortPair', $true)
    $columnType = $assembly.GetType('SUTWinExplorer.DirectorySortColumn', $true)
    $criterionType = $assembly.GetType('SUTWinExplorer.DirectorySortCriterion', $true)
    function Get-SortedPaths([string] $column, [string] $criterion, [string] $pattern = '') {
        $state = [Activator]::CreateInstance($sortType, $true)
        $pair = [Activator]::CreateInstance($pairType, [object[]] @(
            [Enum]::Parse($columnType, $column), [Enum]::Parse($criterionType, $criterion)))
        $pairs = [Array]::CreateInstance($pairType, 1)
        $pairs.SetValue($pair, 0)
        $null = $sortType.GetMethod('Update', $flags).Invoke($state, [object[]] @(,$pairs))
        $snapshot = $openSorted.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true, [bool] $false,
            [string] $pattern, $state, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        return ,@($snapshot.GetType().GetProperty('Items', $flags).GetValue($snapshot) | ForEach-Object {
            $_.GetType().GetProperty('FullPath', $flags).GetValue($_)
        })
    }
    $filteredPaths = Get-SortedPaths 'Name' 'Ascending' 'first*'
    Assert-True ($filteredPaths.Count -eq 1) 'Name filter did not restrict the snapshot.'
    $getUncached = $provider.GetMethod('GetSmallIconsUncached', $staticFlags)
    $indexProperty = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true).GetProperty('BaseIconIndex', $flags)
    foreach ($name in @('first.txt', 'second.exe', 'third.png')) {
        $path = Join-Path $sortDirectory $name
        $cachedSortIcon = Find-Icon $providerCache $path 'small' 16 16
        Assert-True ($null -ne $cachedSortIcon -and $null -ne $cachedSortIcon.BaseIconIndex) 'Directory icon and Windows index were not cached before sorting.'
        $shellSortIcon = $getUncached.Invoke($null, [object[]] @([string] $path))
        Assert-True ($cachedSortIcon.BaseIconIndex -eq $indexProperty.GetValue($shellSortIcon)) 'Cached index differs from the Windows icon index.'
    }
    $saveProvider.Invoke($null, @())
    $initialize.Invoke($null, [object[]] @([string] $filePath))
    $providerCache = $provider.GetField('_cache', $staticFlags).GetValue($null)
    foreach ($name in @('first.txt', 'second.exe', 'third.png')) {
        $path = Join-Path $sortDirectory $name
        Assert-True ($null -ne (Find-Icon $providerCache $path 'small' 16 16).BaseIconIndex) 'Windows icon index was not restored after saving.'
    }
    foreach ($column in @('TypeApp1Icon')) {
        foreach ($criterion in @('Ascending', 'Descending')) {
            $withCache = (Get-SortedPaths $column $criterion) -join '|'
            $provider.GetField('_cache', $staticFlags).SetValue($null, $null)
            $withoutCache = (Get-SortedPaths $column $criterion) -join '|'
            $provider.GetField('_cache', $staticFlags).SetValue($null, $providerCache)
            Assert-True ($withCache -ceq $withoutCache) "$column $criterion sort changed with the persistent cache."
        }
    }
    $sortNames = @('first.txt', 'second.exe', 'third.png')
    for ($index = 0; $index -lt $sortNames.Count; $index++) {
        $path = Join-Path $sortDirectory $sortNames[$index]
        Store-Icon $providerCache $path 'small' 16 16 $bitmap $false ([int] (1000003 - $index))
    }
    $saveProvider.Invoke($null, @())
    $initialize.Invoke($null, [object[]] @([string] $filePath))
    $providerCache = $provider.GetField('_cache', $staticFlags).GetValue($null)
    $sortedPaths = Get-SortedPaths 'TypeApp1Icon' 'Ascending'
    $sortedNames = @($sortedPaths | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    Assert-True (($sortedNames -join ',') -ceq 'third.png,second.exe,first.txt') "Icon sort did not use persisted per-path indices: $($sortedNames -join ',')."
    $sortedPaths = Get-SortedPaths 'TypeApp1Icon' 'Descending'
    $sortedNames = @($sortedPaths | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    Assert-True (($sortedNames -join ',') -ceq 'first.txt,second.exe,third.png') 'Descending icon sort did not use persisted indices.'
    if (-not $cached.HasOverlay) {
        [System.IO.File]::Delete($shellPath)
        Assert-True ($null -ne $getSmall.Invoke($null, [object[]] @([string] $shellPath)).BaseIcon) 'Cached icon was not used after the source disappeared.'
        Assert-True ($null -ne $getSized.Invoke($null, [object[]] @([string] $shellPath, [int] 32, [int] 32))) 'Cached sized icon was not used after the source disappeared.'
    }
    'Icon cache tests passed.'
} finally {
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}