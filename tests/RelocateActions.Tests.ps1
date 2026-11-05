. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll')))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$root = Join-Path ([IO.Path]::GetTempPath()) ('kis-relocate-actions-' + [guid]::NewGuid().ToString('N'))
$previousContext = [System.Threading.SynchronizationContext]::Current
$view = $null
$window = $null
try {
    $source = Join-Path $root 'source'
    $destination = Join-Path $root 'destination'
    [void] [IO.Directory]::CreateDirectory((Join-Path $source 'child'))
    [void] [IO.Directory]::CreateDirectory($destination)
    [IO.File]::WriteAllText((Join-Path $source 'child\file.txt'), 'content')
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = $assembly.GetType('SUTWinExplorer.Pathview', $true).GetConstructors()[0].Invoke([object[]] @([string] $source, $false, $null, $null, $null, $null))
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Content = $view
    $window.Show()
    $relocate = $view.GetType().GetMethod('RelocateCurrentDirectory', $flags)

    foreach ($invalidDestination in @((Join-Path $source 'child\nested'), (Join-Path $root 'missing-parent\name'), $destination, [IO.Path]::GetPathRoot($root))) {
        $failed = $false
        try { $null = $relocate.Invoke($view, [object[]] @([string] $invalidDestination, $true)) } catch { $failed = $true }
        Assert-True ($failed -and $view.CurrentPath -ceq $source -and [IO.Directory]::Exists($source)) "Invalid named destination was not rejected: $invalidDestination"
    }
    $null = $relocate.Invoke($view, [object[]] @([string] $destination, $false))
    $moved = Join-Path $destination 'source'
    Assert-True ($view.CurrentPath -ceq $moved -and -not [IO.Directory]::Exists($source) -and [IO.File]::Exists((Join-Path $moved 'child\file.txt'))) 'Relocation to a parent did not move the directory and its contents.'
    $named = Join-Path $root 'renamed'
    $null = $relocate.Invoke($view, [object[]] @([string] $named, $true))
    Assert-True ($view.CurrentPath -ceq $named -and -not [IO.Directory]::Exists($moved) -and [IO.File]::Exists((Join-Path $named 'child\file.txt'))) 'Relocation with a new name did not move the directory and its contents.'
    $sameParent = Join-Path $root 'renamed-in-place'
    $null = $relocate.Invoke($view, [object[]] @([string] $sameParent, $true))
    Assert-True ($view.CurrentPath -ceq $sameParent -and -not [IO.Directory]::Exists($named) -and [IO.File]::Exists((Join-Path $sameParent 'child\file.txt'))) 'Relocation within the same parent did not rename the directory.'
    'Relocate action tests passed.'
} finally {
    if ($null -ne $view) { $view.GetType().GetMethod('Close', $flags).Invoke($view, @()) }
    if ($null -ne $window) { $window.Close() }
    [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    $application.Shutdown()
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}