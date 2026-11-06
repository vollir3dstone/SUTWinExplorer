. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$openDirectory = $shell.GetMethod('OpenDirectoryAsync', $flags)
$openSortedDirectory = $shell.GetMethod('OpenSortedDirectoryAsync', $flags)
$openCachedDirectory = $shell.GetMethod('OpenCachedDirectoryAsync', $flags)
$cacheType = $assembly.GetType('SUTWinExplorer.DirectoryDataCache', $true)
$sortPairType = $assembly.GetType('SUTWinExplorer.DirectorySortPair', $true)
$sortColumnType = $assembly.GetType('SUTWinExplorer.DirectorySortColumn', $true)
$sortCriterionType = $assembly.GetType('SUTWinExplorer.DirectorySortCriterion', $true)
$sortStateType = $assembly.GetType('SUTWinExplorer.DirectorySortState', $true)
$getRange = $shell.GetMethod('GetDirectoryRangeAsync', $flags)
$ensureAccessible = $shell.GetMethod('EnsureDirectoryAccessible', $flags)
$observe = $shell.GetMethod('ObserveDirectories', $flags)
$rename = $shell.GetMethod('Rename', $flags)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-shell-test-' + [guid]::NewGuid().ToString('N'))

try {
    $mediaMap = $assembly.GetType('SUTWinExplorer.MediaTypeMap', $true)
    $getMediaType = $mediaMap.GetMethod('GetMediaType')
    $getMediaTypeSubType = $mediaMap.GetMethod('GetMediaTypeSubType')
    $formatMediaTypeSubType = $mediaMap.GetMethod('FormatMediaTypeSubType')
    $mediaCases = @(
        @('notes.txt', $false, 'LinesText', 'TEXT', 'TE'),
        @('data.JSON', $false, 'StructuredData', 'TEXT', 'TE'),
        @('data.xlsx', $false, 'StructuredData', 'EDIT', 'ED'),
        @('code.cs', $false, 'CommandData', 'TEXT', 'TE'),
        @('book.html', $false, 'Book', 'TEXT', 'TE'),
        @('book.md', $false, 'Book', 'TEXT', 'TE'),
        @('book.pdf', $false, 'Book', 'RENDER', 'RE'),
        @('book.docx', $false, 'Book', 'EDIT', 'ED'),
        @('image.png', $false, 'Image', 'RENDER', 'RE'),
        @('image.svg', $false, 'Image', 'TEXT', 'TE'),
        @('image.psd', $false, 'Image', 'EDIT', 'ED'),
        @('audio.mp3', $false, 'Audio', 'RENDER', 'RE'),
        @('video.ts', $false, 'Video', 'RENDER', 'RE'),
        @('archive.zip', $false, 'Box', 'EDIT', 'ED'),
        @('program.exe', $false, 'Executable', 'WITHOUT_SUBTYPE', ''),
        @('unknown.xyz', $false, 'None', 'WITHOUT_SUBTYPE', ''),
        @('folder.pdf', $true, 'Directory', 'WITHOUT_SUBTYPE', ''),
        @('shortcut.lnk', $false, 'ShellLink', 'WITHOUT_SUBTYPE', ''),
        @('shortcut.url', $false, 'Url', 'WITHOUT_SUBTYPE', '')
    )
    foreach ($case in $mediaCases) {
        $arguments = [object[]] @([string] $case[0], [bool] $case[1])
        $type = $getMediaType.Invoke($null, $arguments)
        $mediaTypeSubType = $getMediaTypeSubType.Invoke($null, $arguments)
        $text = $formatMediaTypeSubType.Invoke($null, [object[]] @($mediaTypeSubType))
        Assert-True ($type.ToString() -ceq $case[2] -and $mediaTypeSubType.ToString() -ceq $case[3] -and $text -ceq $case[4]) "Media type or media type sub type mismatch for $($case[0])."
    }
    $directoryItemType = $assembly.GetType('SUTWinExplorer.DirectoryItem', $true)
    $directoryItem = [Activator]::CreateInstance($directoryItemType, [object[]] @('book.pdf', 'book.pdf', $false, $false))
    $itemMediaTypeSubType = $directoryItemType.GetProperty('MediaTypeSubType', [System.Reflection.BindingFlags]'Instance,NonPublic').GetValue($directoryItem)
    Assert-True ($itemMediaTypeSubType.ToString() -ceq 'RENDER') 'Directory item did not retain its media type sub type.'
    $mediaTypeSubTypeType = $assembly.GetType('SUTWinExplorer.MediaTypeSubType', $true)
    $getMediaTypeSubTypeIcon = $assembly.GetType('SUTWinExplorer.MediaTypeIconMap', $true).GetMethod('GetMediaTypeSubTypeIcon')
    foreach ($iconCase in @(@('TEXT', 'subtype_text 16.png'), @('EDIT', 'subtype_edit 16.png'), @('RENDER', 'subtype_render.png'))) {
        $mediaTypeSubType = [Enum]::Parse($mediaTypeSubTypeType, $iconCase[0])
        $icon = $getMediaTypeSubTypeIcon.Invoke($null, [object[]] @($mediaTypeSubType))
        $sameIcon = $getMediaTypeSubTypeIcon.Invoke($null, [object[]] @($mediaTypeSubType))
        $resource = [System.Windows.Application]::GetResourceStream([uri]::new("/Assets/$($iconCase[1])", [UriKind]::Relative))
        try {
            $expected = [System.Windows.Media.Imaging.BitmapFrame]::Create($resource.Stream, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        } finally { $resource.Stream.Dispose() }
        $actualPixels = [byte[]]::new(16 * 16 * 4)
        $expectedPixels = [byte[]]::new(16 * 16 * 4)
        ([System.Windows.Media.Imaging.FormatConvertedBitmap]::new($icon, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)).CopyPixels($actualPixels, 64, 0)
        ([System.Windows.Media.Imaging.FormatConvertedBitmap]::new($expected, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)).CopyPixels($expectedPixels, 64, 0)
        Assert-True ($icon.PixelWidth -eq 16 -and $icon.PixelHeight -eq 16 -and $icon.IsFrozen -and
            [object]::ReferenceEquals($icon, $sameIcon) -and [Convert]::ToBase64String($actualPixels) -ceq [Convert]::ToBase64String($expectedPixels)) "Incorrect or uncached media type sub type icon for $($iconCase[0])."
    }
    $withoutMediaTypeSubType = [Enum]::Parse($mediaTypeSubTypeType, 'WITHOUT_SUBTYPE')
    Assert-True ($null -eq $getMediaTypeSubTypeIcon.Invoke($null, [object[]] @($withoutMediaTypeSubType))) 'An absent media type sub type must not have an icon.'

    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'hello')
    [System.IO.File]::SetLastWriteTime((Join-Path $directory 'notes.txt'), [datetime]::new(2026, 11, 2, 9, 5, 0))
    [System.IO.File]::WriteAllText((Join-Path $directory '.internal'), 'hidden')
    [System.IO.File]::WriteAllText((Join-Path $directory 'unknown.zzzunknown'), 'unknown')
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'empty.bin'), [byte[]]::new(0))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'exact.bin'), [byte[]]::new(1024))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'over.bin'), [byte[]]::new(1025))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'large.bin'), [byte[]]::new(1048576))
    foreach ($badName in @('', '..', 'invalid/name', 'exact.bin')) {
        $failed = $false
        try { $null = $rename.Invoke($null, [object[]] @([string] (Join-Path $directory 'notes.txt'), [string] $badName, [IntPtr]::Zero)) } catch {
            $expectedType = if ($badName -eq 'exact.bin') { [System.IO.IOException] } else { [System.ArgumentException] }
            $failed = $expectedType.IsInstanceOfType($_.Exception.InnerException)
        }
        Assert-True $failed "Invalid or conflicting rename was accepted: $badName"
    }
    $casePath = Join-Path $directory 'case-only.tmp'
    [System.IO.File]::WriteAllText($casePath, 'case')
    $caseResult = $rename.Invoke($null, [object[]] @([string] $casePath, [string] 'CASE-only.tmp', [IntPtr]::Zero))
    $caseNames = @([System.IO.Directory]::EnumerateFileSystemEntries($directory) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    Assert-True ($caseResult -ceq (Join-Path $directory 'CASE-only.tmp') -and $caseNames -ccontains 'CASE-only.tmp') 'Case-only rename failed.'
    [System.IO.File]::Delete($caseResult)

    $sortDirectory = Join-Path $directory 'sorting-fixture'
    try {
        [System.IO.Directory]::CreateDirectory((Join-Path $sortDirectory 'Z-folder')) | Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $sortDirectory 'A-folder')) | Out-Null
        foreach ($case in @(@('a.bin', 2, 1), @('b.bin', 2, 2), @('c.txt', 10, 1), @('d.txt', 1, 2))) {
            $path = Join-Path $sortDirectory $case[0]
            [System.IO.File]::WriteAllBytes($path, [byte[]]::new($case[1]))
            [System.IO.File]::SetLastWriteTime($path, [datetime]::new(2026, 1, $case[2]))
        }
        $sortState = [Activator]::CreateInstance($sortStateType, $true)
        $instanceFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $updateSort = $sortStateType.GetMethod('Update', $instanceFlags)
        $pairsProperty = $sortStateType.GetProperty('Pairs', $instanceFlags)
        function New-SortPair([string] $column, [string] $criterion) {
            [Activator]::CreateInstance($sortPairType, [object[]] @(
                [Enum]::Parse($sortColumnType, $column), [Enum]::Parse($sortCriterionType, $criterion)))
        }
        function Set-TestSort($state, [object[]] $pairs) {
            $array = [Array]::CreateInstance($sortPairType, $pairs.Count)
            for ($index = 0; $index -lt $pairs.Count; $index++) { $array.SetValue($pairs[$index], $index) }
            $null = $updateSort.Invoke($state, [object[]] @(,$array))
        }
        function Get-SortedNames($state) {
            $result = $openSortedDirectory.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true,
                [bool] $false, [string] '', $state, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
            $entries = $getRange.Invoke($null, [object[]] @($result, [int] 0, [int] $result.Count,
                [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
            return ,@($entries | ForEach-Object { [System.IO.Path]::GetFileName($_.FullPath) })
        }
        Set-TestSort $sortState @((New-SortPair 'Name' 'Descending'))
        Assert-True ((Get-SortedNames $sortState) -join ',' -ceq 'Z-folder,A-folder,d.txt,c.txt,b.bin,a.bin') 'Name descending or directory grouping failed.'
        Set-TestSort $sortState @((New-SortPair 'Size' 'Ascending'))
        Assert-True ((Get-SortedNames $sortState) -join ',' -ceq 'Z-folder,A-folder,d.txt,b.bin,a.bin,c.txt') 'Numeric size sort or secondary name sort failed.'
        Set-TestSort $sortState @((New-SortPair 'Size' 'Descending'))
        Assert-True ((Get-SortedNames $sortState) -join ',' -ceq 'Z-folder,A-folder,c.txt,b.bin,a.bin,d.txt') 'Size direction change or sort history failed.'
        Set-TestSort $sortState @((New-SortPair 'DateModified' 'Ascending'), (New-SortPair 'Name' 'Ascending'))
        Assert-True ((Get-SortedNames $sortState)[2..5] -join ',' -ceq 'a.bin,c.txt,b.bin,d.txt') 'Multi-column update or date sorting failed.'
        $history = @($pairsProperty.GetValue($sortState))
        Assert-True (($history.Column -join ',') -ceq 'DateModified,Name,Size') 'Updating a sort column did not move it to the front without duplication.'
        $invalid = $false
        try { Set-TestSort $sortState @((New-SortPair 'Name' 'Ascending'), (New-SortPair 'Name' 'Descending')) } catch { $invalid = $true }
        Assert-True ($invalid -and (@($pairsProperty.GetValue($sortState)).Column -join ',') -ceq 'DateModified,Name,Size') 'Duplicate columns were accepted or changed sort history.'
        foreach ($column in @('TypeApp2Name', 'MediaTypeIcon')) {
            Set-TestSort $sortState @((New-SortPair $column 'Ascending'))
            $sortedNames = Get-SortedNames $sortState
            Assert-True ($sortedNames.Count -eq 6 -and $sortedNames[0] -in @('A-folder', 'Z-folder') -and $sortedNames[1] -in @('A-folder', 'Z-folder')) "$column sort lost items or directory grouping."
            $mediaMap = $assembly.GetType('SUTWinExplorer.MediaTypeMap', $true)
            $previous = $null
            foreach ($name in $sortedNames[2..5]) {
                $path = Join-Path $sortDirectory $name
                $key = if ($column -eq 'TypeApp2Name') { [SutShellTestTypeName]::Get($path) } else {
                    $mediaType = $mediaMap.GetMethod('GetMediaType').Invoke($null, [object[]] @([string] $path, [bool] $false))
                    if ([int] $mediaType -eq 0) { [int]::MaxValue } else { [int] $mediaType }
                }
                $inOrder = if ($null -eq $previous) { $true } elseif ($column -eq 'TypeApp2Name') {
                    [StringComparer]::CurrentCultureIgnoreCase.Compare($previous, $key) -le 0
                } else { $previous -le $key }
                Assert-True $inOrder "$column keys are not in ascending order."
                $previous = $key
            }
        }
        [System.IO.File]::WriteAllBytes((Join-Path $sortDirectory 'picture.png'), [byte[]]::new(0))
        [System.IO.File]::WriteAllBytes((Join-Path $sortDirectory 'archive.zip'), [byte[]]::new(0))
        $mediaOrder = [Activator]::CreateInstance($sortStateType, $true)
        Set-TestSort $mediaOrder @((New-SortPair 'MediaTypeIcon' 'Ascending'))
        $mediaNames = Get-SortedNames $mediaOrder
        Assert-True ([Array]::IndexOf($mediaNames, 'picture.png') -lt [Array]::IndexOf($mediaNames, 'archive.zip')) 'Media types are not sorted by enum order.'
        Assert-True (($mediaNames[2..7] -join ',') -ceq 'c.txt,d.txt,picture.png,archive.zip,a.bin,b.bin') 'Files without a media type must follow known media types in ascending order.'
        Set-TestSort $mediaOrder @((New-SortPair 'MediaTypeIcon' 'Descending'))
        $mediaNames = Get-SortedNames $mediaOrder
        Assert-True (($mediaNames[2..7] -join ',') -ceq 'archive.zip,picture.png,c.txt,d.txt,a.bin,b.bin') 'Files without a media type must follow known media types in descending order.'
        Set-TestSort $mediaOrder @((New-SortPair 'Size' 'Ascending'), (New-SortPair 'MediaTypeIcon' 'Ascending'))
        $mediaNames = Get-SortedNames $mediaOrder
        Assert-True (($mediaNames[2..7] -join ',') -ceq 'picture.png,archive.zip,d.txt,a.bin,b.bin,c.txt') 'A secondary media-type sort must not override the primary size sort.'
        [System.IO.File]::Delete((Join-Path $sortDirectory 'picture.png'))
        [System.IO.File]::Delete((Join-Path $sortDirectory 'archive.zip'))
        $cache = [Activator]::CreateInstance($cacheType, $true)
        $cacheSort = [Activator]::CreateInstance($sortStateType, $true)
        function Get-CachedSnapshot([string] $pattern) {
            $openCachedDirectory.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true, [bool] $false,
                [string] $pattern, $cacheSort, $cache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        }
        function Get-SnapshotEntries($sourceSnapshot) {
            return ,@($getRange.Invoke($null, [object[]] @($sourceSnapshot, [int] 0, [int] $sourceSnapshot.Count,
                [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
        }
        $initialSnapshot = Get-CachedSnapshot ''
        $overlayTask = $initialSnapshot.GetType().GetProperty('OverlayCompletion', $instanceFlags).GetValue($initialSnapshot)
        if ($null -ne $overlayTask) { $overlayTask.GetAwaiter().GetResult(); $initialSnapshot = Get-CachedSnapshot '' }
        $initialEntries = Get-SnapshotEntries $initialSnapshot
        $cachedFile = @($initialEntries | Where-Object { $_.FullPath -eq (Join-Path $sortDirectory 'a.bin') })[0]
        [System.IO.File]::WriteAllBytes((Join-Path $sortDirectory 'a.bin'), [byte[]]::new(2048))
        [System.IO.File]::WriteAllText((Join-Path $sortDirectory 'new-file.txt'), 'new')
        $filteredCache = Get-CachedSnapshot '*.txt'
        Assert-True ($filteredCache.Count -eq 2 -and $filteredCache.DirectoryCount -eq 2 -and $filteredCache.FileCount -eq 4) 'Filtered snapshots must preserve unfiltered cached directory and file counts.'
        Set-TestSort $cacheSort @((New-SortPair 'Size' 'Descending'))
        $reusedSnapshot = Get-CachedSnapshot ''
        $reusedEntries = Get-SnapshotEntries $reusedSnapshot
        $reusedFile = @($reusedEntries | Where-Object { $_.FullPath -eq $cachedFile.FullPath })[0]
        Assert-True ($reusedSnapshot.Count -eq 6 -and [object]::ReferenceEquals($cachedFile, $reusedFile) -and
            $reusedFile.SizeText -ceq $cachedFile.SizeText -and [object]::ReferenceEquals($reusedFile.Icons, $cachedFile.Icons)) 'Filtering or sorting discarded cached entry data.'
        foreach ($column in @('TypeApp1Icon')) {
            Set-TestSort $cacheSort @((New-SortPair $column 'Ascending'))
            $iconEntries = Get-SnapshotEntries (Get-CachedSnapshot '')
            $iconKeyName = if ($column -eq 'TypeApp1Icon') { 'BaseIconIndex' } else { 'OverlaySlot' }
            $iconProperty = $assembly.GetType('SUTWinExplorer.ShellIconSet').GetProperty($iconKeyName, $instanceFlags)
            $previous = $null
            foreach ($entry in @($iconEntries | Where-Object { -not $_.IsDirectory })) {
                $key = if ($null -ne $entry.Icons) { $iconProperty.GetValue($entry.Icons) } else { $null }
                Assert-True ($null -eq $previous -or ($null -ne $key -and $previous -le $key)) "$column keys are not in ascending order."
                $previous = $key
            }
            Set-TestSort $cacheSort @((New-SortPair $column 'Descending'))
            $reverseEntries = Get-SnapshotEntries (Get-CachedSnapshot '')
            $previous = $null
            foreach ($entry in @($reverseEntries | Where-Object { -not $_.IsDirectory -and $null -ne $_.Icons })) {
                $key = $iconProperty.GetValue($entry.Icons)
                Assert-True ($null -eq $previous -or $previous -ge $key) "$column keys are not in descending order."
                $previous = $key
            }
        }
        $overlayRejected = $false
        try { Set-TestSort $cacheSort @((New-SortPair 'Overlay' 'Ascending')) }
        catch { $overlayRejected = $_.Exception.ToString().Contains('ArgumentException') }
        Assert-True $overlayRejected 'Overlay sorting must be rejected.'
        $null = $cacheType.GetMethod('Invalidate', $instanceFlags).Invoke($cache, @())
        $refreshedSnapshot = Get-CachedSnapshot ''
        $refreshedEntries = Get-SnapshotEntries $refreshedSnapshot
        $refreshedFile = @($refreshedEntries | Where-Object { $_.FullPath -eq $cachedFile.FullPath })[0]
        Assert-True ($refreshedSnapshot.Count -eq 7 -and $refreshedSnapshot.DirectoryCount -eq 2 -and $refreshedSnapshot.FileCount -eq 5 -and -not [object]::ReferenceEquals($cachedFile, $refreshedFile) -and
            $refreshedFile.SizeText -ceq ('{0:N0} KB' -f 2)) 'Invalidation did not refresh directory membership and metadata.'
        $freshCache = [Activator]::CreateInstance($cacheType, $true)
        $iconSort = [Activator]::CreateInstance($sortStateType, $true)
        Set-TestSort $iconSort @((New-SortPair 'TypeApp1Icon' 'Ascending'))
        $firstIconSnapshot = $openCachedDirectory.Invoke($null, [object[]] @([string] $sortDirectory, [bool] $true,
            [bool] $false, [string] '', $iconSort, $freshCache, [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
        $itemsProperty = $firstIconSnapshot.GetType().GetProperty('Items', $instanceFlags)
        $firstIconItem = @($itemsProperty.GetValue($firstIconSnapshot))[0]
        $iconsProperty = $firstIconItem.GetType().GetProperty('Icons', $instanceFlags)
        $cachedIcon = $iconsProperty.GetValue($firstIconItem)
        $firstIconEntries = Get-SnapshotEntries $firstIconSnapshot
        Assert-True ($null -ne $cachedIcon -and [object]::ReferenceEquals($cachedIcon, $firstIconEntries[0].Icons)) 'Initial icon sort did not reuse its loaded icon for the row.'
    } finally { [System.IO.Directory]::Delete($sortDirectory, $true) }

    $snapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    Assert-True ($snapshot.Count -eq 8) 'Snapshot count is incorrect.'
    $all = @($getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($all.Count -eq 8 -and $all[0].IsDirectory) 'Enumeration or directory-first ordering failed.'
    $notes = $all | Where-Object { $_.FullPath -eq (Join-Path $directory 'notes.txt') }
    Assert-True ($null -ne $notes.Icons -and $notes.MediaTypeName -eq 'lines-text' -and $null -ne $notes.MediaTypeIcon) 'Shell icon or media type is missing.'
    $previousCulture = [System.Globalization.CultureInfo]::CurrentCulture
    try {
        foreach ($cultureName in @('de-DE', 'en-US', 'th-TH')) {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureName)
            Assert-True ($notes.ModifiedText -ceq '2026-11-02 09:05') "Date format changed under $cultureName."
        }
    } finally {
        [System.Globalization.CultureInfo]::CurrentCulture = $previousCulture
    }
    $unknown = $all | Where-Object { $_.FullPath -eq (Join-Path $directory 'unknown.zzzunknown') }
    Assert-True ($unknown.MediaTypeName -eq '' -and $null -eq $unknown.MediaTypeIcon) 'Unknown media type must be empty.'
    foreach ($entry in @($notes, $unknown, $all[0])) {
        Assert-True ($entry.Type -ceq [SutShellTestTypeName]::Get($entry.FullPath)) "Shell type mismatch for $($entry.FullPath)."
    }
    foreach ($case in @(@('empty.bin', 0), @('notes.txt', 1), @('exact.bin', 1), @('over.bin', 2), @('large.bin', 1024))) {
        $entry = $all | Where-Object { $_.FullPath -eq (Join-Path $directory $case[0]) }
        $expected = '{0:N0} KB' -f $case[1]
        Assert-True ($entry.SizeText -ceq $expected) "Size mismatch for $($case[0]): $($entry.SizeText)."
    }
    Assert-True ($all[0].SizeText -eq '') 'Directory size must be empty.'

    $page = @($getRange.Invoke($null, [object[]] @($snapshot, [int] 2, [int] 3, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($page.Count -eq 3 -and $page[0].FullPath -eq $all[2].FullPath -and $page[2].FullPath -eq $all[4].FullPath) 'Requested range does not match the snapshot order.'
    Assert-True ($notes.Icons.BaseIcon.IsFrozen -and $notes.MediaTypeIcon.IsFrozen) 'Complete row images must be frozen for the UI thread.'
    $parallelRanges = @(1..12 | ForEach-Object {
        $getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None))
    })
    foreach ($task in $parallelRanges) {
        $parallelEntries = @($task.GetAwaiter().GetResult())
        Assert-True ($parallelEntries.Count -eq $snapshot.Count -and $null -ne $parallelEntries[0].Icons.BaseIcon) 'Concurrent range loading lost a Shell icon.'
    }
    $emptyPage = @($getRange.Invoke($null, [object[]] @($snapshot, [int] $snapshot.Count, [int] 0, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($emptyPage.Count -eq 0) 'Empty range must return no items.'
    $invalidRange = $false
    try { $null = $getRange.Invoke($null, [object[]] @($snapshot, [int] $snapshot.Count, [int] 1, [Threading.CancellationToken]::None)) } catch { $invalidRange = $true }
    Assert-True $invalidRange 'An out-of-bounds range was accepted.'
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-a.txt'), 'gone')
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-b.txt'), 'present')
    $changingSnapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] 'vanish-*.txt', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    [System.IO.File]::Delete((Join-Path $directory 'vanish-a.txt'))
    $changedPage = @($getRange.Invoke($null, [object[]] @($changingSnapshot, [int] 0, [int] 2, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($changingSnapshot.Count -eq 2 -and $changedPage.Count -eq 2 -and $changedPage[1].FullPath -eq (Join-Path $directory 'vanish-b.txt') -and $null -ne $changedPage[1].Icons) 'A vanished item changed the snapshot range or blocked its neighbor.'
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $cancellation.Cancel()
        $cancelledTask = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', $cancellation.Token))
        $cancelled = $false
        try { $null = $cancelledTask.GetAwaiter().GetResult() } catch { $cancelled = $true }
        Assert-True ($cancelled -and $cancelledTask.IsCanceled) 'Cancelled enumeration completed instead of cancelling.'
        $cancelledRange = $getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] 1, $cancellation.Token))
        $cancelled = $false
        try { $null = $cancelledRange.GetAwaiter().GetResult() } catch { $cancelled = $true }
        Assert-True ($cancelled -and $cancelledRange.IsCanceled) 'Cancelled range lookup completed instead of cancelling.'
    } finally {
        $cancellation.Dispose()
    }

    $filteredSnapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $false, [bool] $true, [string] 'notes*.TXT', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    $filtered = @($getRange.Invoke($null, [object[]] @($filteredSnapshot, [int] 0, [int] $filteredSnapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($filtered.Count -eq 1 -and $filtered[0].FullPath -eq $notes.FullPath -and
        $filteredSnapshot.DirectoryCount -eq @([IO.Directory]::EnumerateDirectories($directory)).Count -and
        $filteredSnapshot.FileCount -eq @([IO.Directory]::EnumerateFiles($directory)).Count) 'Filters changed the unfiltered counts or failed to filter the displayed items.'
    $top = $openDirectory.Invoke($null, [object[]] @([string] '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}', [bool] $false, [bool] $true, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    Assert-True ($top.Count -eq 0 -and $top.DirectoryCount -eq [IO.DriveInfo]::GetDrives().Count -and $top.FileCount -eq 0) 'This PC must filter its list without changing the drive count.'

    $failed = $false
    try { $ensureAccessible.Invoke($null, @((Join-Path $directory 'missing'))) } catch { $failed = $true }
    Assert-True $failed 'A missing directory was accepted.'

    $signal = [SutShellTestSignal]::new()
    $callback = [Delegate]::CreateDelegate([Action], $signal, 'Notify')
    $observer = $observe.Invoke($null, @([string[]] @($directory), $callback))
    try {
        [System.IO.File]::WriteAllText((Join-Path $directory 'created.txt'), 'new')
        Assert-True ($signal.Event.WaitOne(5000)) 'External changes were not observed.'
    } finally {
        $observer.Dispose()
        $signal.Event.Dispose()
    }
    'SutShell tests passed.'
} finally {
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}