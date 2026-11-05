$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
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

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-rename-' + [guid]::NewGuid().ToString('N'))
$oldPath = Join-Path $root 'old-name'
$newPath = Join-Path $root 'new-name'
$view = $null
$window = $null
try {
    [void] [IO.Directory]::CreateDirectory($oldPath)
    [IO.File]::WriteAllText((Join-Path $oldPath 'file.txt'), 'content')
    $constructor = $assembly.GetType('SUTWinExplorer.Pathview', $true).GetConstructors()[0]
    $view = $constructor.Invoke([object[]] @([string] $oldPath, $false, $null, $null, $null, $null))
    $content = $view.FindName('DirectoryContent')
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $cache = $content.GetType().GetField('_directoryCache', $flags).GetValue($content)
    $generation = $cache.GetType().GetField('_generation', $flags)
    $items = $cache.GetType().GetField('_items', $flags)
    $snapshot = $content.GetType().GetField('_snapshot', $flags)
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Width = 800
    $window.Height = 600
    $window.Content = $view
    $window.Show()
    Wait-Until { $null -ne $snapshot.GetValue($content) -and $null -ne $items.GetValue($cache) } 'The initial directory did not load.'
    Wait-Until { $null -ne @($content.FindName('FileList').Items)[0].Entry } 'The initial item details did not load.'
    Pump 500
    $list = $content.FindName('FileList')
    $list.SelectedItem = $list.Items[0]
    $initialGeneration = $generation.GetValue($cache)
    $initialItems = $items.GetValue($cache)
    [IO.Directory]::Move($oldPath, $newPath)
    $view.GetType().GetMethod('ApplyDirectoryRename', $flags).Invoke($view, [object[]] @([string] $oldPath, [string] $newPath))
    Pump 500
    if ($view.CurrentPath -cne $newPath) { throw 'The renamed Pathview path was not updated.' }
    if ($generation.GetValue($cache) -ne $initialGeneration -or -not [object]::ReferenceEquals($initialItems, $items.GetValue($cache))) { throw 'Renaming the Pathview invalidated or re-enumerated its contents.' }
    if ($view.GetType().GetField('_enumerationDirty', $flags).GetValue($view) -or $view.GetType().GetField('_displayDirty', $flags).GetValue($view)) { throw 'Renaming the Pathview set a dirty flag.' }
    if ($list.SelectedItem.FullPath -cne (Join-Path $newPath 'file.txt') -or $list.SelectedItem.Entry.FullPath -cne (Join-Path $newPath 'file.txt')) { throw 'The selected cached item path was not updated.' }
    $activeEntry = $view.GetType().GetField('_activePathEntry', $flags).GetValue($view)
    if ($activeEntry.Path -cne $newPath) { throw 'The active tree path was not updated.' }

    $window.Hide()
    $externalPath = Join-Path $root 'external-name'
    [IO.Directory]::Move($newPath, $externalPath)
    Wait-Until { $view.CurrentPath -ceq $externalPath } 'The external rename was not detected.'
    Pump 500
    if ($generation.GetValue($cache) -ne $initialGeneration -or -not [object]::ReferenceEquals($initialItems, $items.GetValue($cache))) { throw 'The external rename invalidated or re-enumerated the Pathview.' }
    if ($view.GetType().GetField('_enumerationDirty', $flags).GetValue($view) -or $view.GetType().GetField('_displayDirty', $flags).GetValue($view)) { throw 'The external rename set a dirty flag on the Pathview.' }
    if ($list.SelectedItem.FullPath -cne (Join-Path $externalPath 'file.txt')) { throw 'The external rename did not retain the selected item.' }
    $casePath = Join-Path $root 'External-Name'
    [IO.Directory]::Move($externalPath, $casePath)
    Wait-Until { $view.CurrentPath -ceq $casePath } 'The case-only rename was not detected.'
    if ($generation.GetValue($cache) -ne $initialGeneration -or -not [object]::ReferenceEquals($initialItems, $items.GetValue($cache))) { throw 'The case-only rename invalidated the cache.' }
    $externalPath = $casePath
    [IO.File]::WriteAllText((Join-Path $externalPath 'added.txt'), 'new')
    Wait-Until { $view.GetType().GetField('_enumerationDirty', $flags).GetValue($view) } 'The watcher did not follow the renamed directory.'
    $queuedPath = Join-Path $root 'renamed-with-pending-change'
    [IO.Directory]::Move($externalPath, $queuedPath)
    Wait-Until { $view.CurrentPath -ceq $queuedPath } 'The directory rename with a pending change was not detected.'
    $window.Show()
    Wait-Until { @($list.Items | Where-Object { $_.FullPath -eq (Join-Path $queuedPath 'added.txt') }).Count -eq 1 } 'A pending change was lost when the directory was renamed.'
    if ($generation.GetValue($cache) -ne $initialGeneration -or $list.SelectedItem.FullPath -cne (Join-Path $queuedPath 'file.txt')) { throw 'A pending change after directory rename invalidated the cache or lost selection.' }

    Write-Output 'Pathview rename tests passed.'
} finally {
    if ($null -ne $view) { $view.GetType().GetMethod('Close', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($view, @()) }
    if ($null -ne $window) { $window.Close() }
    $application.Shutdown()
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}