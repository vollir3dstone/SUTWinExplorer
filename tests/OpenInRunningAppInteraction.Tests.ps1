$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RunningAppMenuProbe
{
    [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int index);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint index, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint index, StringBuilder text, int length, uint flags);
}
'@
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$previousContext = [Threading.SynchronizationContext]::Current
[Threading.SynchronizationContext]::SetSynchronizationContext([System.Windows.Threading.DispatcherSynchronizationContext]::new())
$instanceFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$staticFlags = [Reflection.BindingFlags]'Static,NonPublic'
$factory = $assembly.GetType('SUTWinExplorer.SutContextMenuFactory', $true)
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutRunningApp-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null

function Test-OpenLocationMenu($instance) {
    $menu = $instance.GetType().GetField('_menu', $instanceFlags).GetValue($instance)
    $context = $instance.GetType().GetField('_contextMenu', $instanceFlags).GetValue($instance)
    $actions = $instance.GetType().GetField('_actions', $instanceFlags).GetValue($instance)
    $actionIndex = [Array]::IndexOf(@($actions | ForEach-Object { $_.Id }), 'opencontaining')
    if ($actionIndex -lt 0) { throw 'The Open file location action was not preserved.' }
    $locationCommand = [uint32] (0x8000 + $actionIndex)
    $verbMethod = $factory.GetMethod('GetCommandVerb', $staticFlags)
    function Test-Level([IntPtr] $level) {
        for ($index = 0; $index -lt [RunningAppMenuProbe]::GetMenuItemCount($level); $index++) {
            $submenu = [RunningAppMenuProbe]::GetSubMenu($level, $index)
            if ($submenu -ne [IntPtr]::Zero) { Test-Level $submenu }
            $id = [RunningAppMenuProbe]::GetMenuItemID($level, $index)
            if ($id -eq $locationCommand) {
                $script:foundLocation++
                if (([RunningAppMenuProbe]::GetMenuState($level, [uint32] $index, 0x400) -band 3) -ne 0) { throw 'The Open file location action was disabled.' }
            } elseif ($id -ge 1 -and $id -le 0x7fff) {
                if ($verbMethod.Invoke($null, [object[]] @($context, [uint32] ($id - 1))) -eq 'opencontaining') { throw 'Native opencontaining was not removed.' }
            }
        }
    }
    $script:foundLocation = 0
    Test-Level $menu
    if ($script:foundLocation -ne 1) { throw "Expected one application Open file location action, found $script:foundLocation." }
}

try {
    $file = Join-Path $directory 'example.txt'
    [IO.File]::WriteAllText($file, 'target')
    $fileLink = Join-Path $directory 'file.lnk'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($fileLink)
        try { $shortcut.TargetPath = $file; $shortcut.Save() }
        finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    } finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }

    $pathview = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true),
        [object[]] @([string] $directory, [bool] $true, $null, $null, $null, $null))
    $view = $pathview.FindName('DirectoryContent')
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = 100
    $window.Top = 100
    $window.Width = 800
    $window.Height = 500
    $window.Content = $pathview
    $window.Show()
    $null = $window.Activate()
    $owner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $createAction = $view.GetType().GetMethod('CreateOpenLocationAction', $instanceFlags)
    $createActions = $view.GetType().GetMethod('CreateContextMenuActions', $instanceFlags)

    $runningActionType = $assembly.GetType('SUTWinExplorer.ShellMenuAction', $true)
    $runningActions = [Array]::CreateInstance($runningActionType, 2)
    $script:chosenRunningApp = ''
    $runningActions[0] = [Activator]::CreateInstance($runningActionType, [object[]] @('running-one', 'App One - First', $true, [Action] { $script:chosenRunningApp = 'first' }, $false, $false))
    $runningActions[1] = [Activator]::CreateInstance($runningActionType, [object[]] @('running-two', 'App Two - Second', $true, [Action] { $script:chosenRunningApp = 'second' }, $false, $false))
    $paths = [string[]] @($fileLink)
    $locationAction = $createAction.Invoke($view, [object[]] @(,$paths))
    $base = $factory.GetMethod('GetBaseMenu', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $createActions.Invoke($view, @())))
    try { $snapshot = $base.GetType().GetMethod('CaptureSnapshot', $instanceFlags).Invoke($base, @()) }
    finally { ([IDisposable] $base).Dispose() }
    $menu = $factory.GetMethod('GetContentMenuForContextWithRunningApps', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $snapshot, $false, $null, $locationAction, $runningActions))
    try {
        $nativeMenu = $menu.GetType().GetField('_menu', $instanceFlags).GetValue($menu)
        $label = [Text.StringBuilder]::new(256)
        [void] [RunningAppMenuProbe]::GetMenuString($nativeMenu, 0, $label, $label.Capacity, 0x400)
        if ($label.ToString() -cne 'Open in running app...') { throw 'The running-app submenu is not the first menu item.' }
        $submenu = [RunningAppMenuProbe]::GetSubMenu($nativeMenu, 0)
        if ($submenu -eq [IntPtr]::Zero -or [RunningAppMenuProbe]::GetMenuItemCount($submenu) -ne 2) { throw 'The running-app submenu does not contain both windows.' }
        for ($index = 0; $index -lt 2; $index++) {
            $label.Clear() | Out-Null
            [void] [RunningAppMenuProbe]::GetMenuString($submenu, [uint32] $index, $label, $label.Capacity, 0x400)
            if ($label.ToString() -cne $runningActions[$index].Label) { throw 'Running-app window labels or order changed.' }
        }
        Test-OpenLocationMenu $menu
        $command = [RunningAppMenuProbe]::GetMenuItemID($submenu, 1)
        $null = $menu.GetType().GetMethod('ExecuteCommand', $instanceFlags).Invoke($menu, [object[]] @($command))
        if ($script:chosenRunningApp -cne 'second') { throw 'The selected running-app window was not invoked.' }
    } finally { ([IDisposable] $menu).Dispose() }
    $emptyActions = [Array]::CreateInstance($runningActionType, 0)
    $menu = $factory.GetMethod('GetContentMenuForContextWithRunningApps', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $snapshot, $false, $null, $null, $emptyActions))
    try {
        $nativeMenu = $menu.GetType().GetField('_menu', $instanceFlags).GetValue($menu)
        if (([RunningAppMenuProbe]::GetMenuState($nativeMenu, 0, 0x400) -band 3) -eq 0) { throw 'An empty running-app submenu was not disabled.' }
    } finally { ([IDisposable] $menu).Dispose() }

    $suffix = [Guid]::NewGuid().ToString('N')
    $extension = ".kisrunning$suffix"
    $progId = "KisMenuRunningApp.$suffix"
    $extensionKey = "Software\Classes\$extension"
    $programKey = "Software\Classes\$progId"
    $testWindow = [System.Windows.Window]::new()
    $secondTestWindow = [System.Windows.Window]::new()
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($extensionKey)
        try { $key.SetValue('', $progId) } finally { $key.Dispose() }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$programKey\shell\open\command")
        try { $key.SetValue('', ('"{0}" "%1"' -f (Get-Process -Id $PID).Path)) } finally { $key.Dispose() }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($programKey)
        try { $key.SetValue('', 'KIS Running App Test') } finally { $key.Dispose() }
        [RunningAppMenuProbe]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        $testWindow.Title = "Running & Window $suffix"
        $testWindow.Show()
        $secondTestWindow.Title = "Running Second Window $suffix"
        $secondTestWindow.Show()
        $runningFile = Join-Path $directory "sample$extension"
        [IO.File]::WriteAllText($runningFile, 'test')
        $createRunning = $view.GetType().GetMethod('CreateRunningAppActions', $instanceFlags)
        $discovered = @($createRunning.Invoke($view, [object[]] @(,[string[]] @($runningFile))))
        if (@($discovered | Where-Object { $_.Label -like "*Running && Window $suffix" }).Count -ne 1) { throw 'The registered application window was not listed with an escaped title.' }
        if (@($discovered | Where-Object { $_.Label -like "*Running Second Window $suffix" }).Count -ne 1) { throw 'The second registered application window was not listed.' }
        $unassociated = Join-Path $directory "sample.kisunknown$suffix"
        [IO.File]::WriteAllText($unassociated, 'test')
        $mixedActions = $createRunning.Invoke($view, [object[]] @(,[string[]] @($runningFile, $unassociated)))
        if (@($mixedActions | Where-Object { $_.Label -like "*Running && Window $suffix" }).Count -ne 0) { throw 'The test application was listed without an association for every selected type.' }
        $directoryActions = $createRunning.Invoke($view, [object[]] @(,[string[]] @($directory)))
        if ($directoryActions.Count -ne 0) { throw 'A directory was offered as a file transfer.' }
    } finally {
        $secondTestWindow.Close()
        $testWindow.Close()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($extensionKey, $false)
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($programKey, $false)
        [RunningAppMenuProbe]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    'Open in running app interaction tests passed.'
} finally {
    if ($null -ne $window) { $window.Close() }
    [Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    [IO.Directory]::Delete($directory, $true)
}