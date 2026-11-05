$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$parseErrors = $null
$suiteAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
$suiteHelpers = $suiteAst.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('public sealed class SutShellTestSignal') }, $true)
Add-Type -TypeDefinition $suiteHelpers.Value
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OpenLocationMenuProbe
{
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu, int index);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint index, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu, uint index, StringBuilder text, int length, uint flags);
}
public sealed class OpenLocationBrowseProbe
{
    public string Path;
    public void OnBrowse(object sender, string path, bool? first, bool? second, bool? third, bool? fourth) { Path = path; }
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
$directory = Join-Path ([IO.Path]::GetTempPath()) ('SutOpenLocation-' + [Guid]::NewGuid().ToString('N'))
$targetDirectory = Join-Path $directory 'target'
$targetFolder = Join-Path $targetDirectory 'folder'
[IO.Directory]::CreateDirectory($targetFolder) | Out-Null
function Get-ActionCommandId($instance, [string] $actionId) {
    $actions = $instance.GetType().GetField('_actions', $instanceFlags).GetValue($instance)
    $actionIndex = [Array]::IndexOf(@($actions | ForEach-Object { $_.Id }), $actionId)
    if ($actionIndex -lt 0) { throw "Missing action: $actionId." }
    [uint32] (0x8000 + $actionIndex)
}
function Check-Menu($instance, [bool] $enabled) {
    $menu = $instance.GetType().GetField('_menu', $instanceFlags).GetValue($instance)
    $context = $instance.GetType().GetField('_contextMenu', $instanceFlags).GetValue($instance)
    $verbMethod = $factory.GetMethod('GetCommandVerb', $staticFlags)
    $locationCommand = Get-ActionCommandId $instance 'opencontaining'
    $found = 0
    function Check-Level([IntPtr] $level) {
        for ($index = 0; $index -lt [OpenLocationMenuProbe]::GetMenuItemCount($level); $index++) {
            $submenu = [OpenLocationMenuProbe]::GetSubMenu($level, $index)
            if ($submenu -ne [IntPtr]::Zero) { Check-Level $submenu }
            $id = [OpenLocationMenuProbe]::GetMenuItemID($level, $index)
            if ($id -eq $locationCommand) {
                $script:foundLocation++
                if ((([OpenLocationMenuProbe]::GetMenuState($level, [uint32] $index, 0x400) -band 3) -eq 0) -ne $enabled) { throw 'Incorrect Open file location enabled state.' }
            } elseif ($id -ge 1 -and $id -le 0x7fff) {
                if ($verbMethod.Invoke($null, [object[]] @($context, [uint32] ($id - 1))) -eq 'opencontaining') { throw 'Native opencontaining was not removed.' }
            }
        }
    }
    $script:foundLocation = 0
    Check-Level $menu
    if ($script:foundLocation -ne 1) { throw "Expected one application Open file location action, found $script:foundLocation." }
}
try {
    $file = Join-Path $targetDirectory 'example.txt'
    [IO.File]::WriteAllText($file, 'target')
    $shell = New-Object -ComObject WScript.Shell
    try {
        $fileLink = Join-Path $directory 'file.lnk'
        $folderLink = Join-Path $directory 'folder.lnk'
        $brokenLink = Join-Path $directory 'broken.lnk'
        foreach ($pair in @(@($fileLink, $file), @($folderLink, $targetFolder), @($brokenLink, (Join-Path $directory 'missing.txt')))) {
            $shortcut = $shell.CreateShortcut($pair[0])
            try { $shortcut.TargetPath = $pair[1]; $shortcut.Save() }
            finally { [void] [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        }
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
    foreach ($case in @(@($fileLink, 'content'), @($fileLink, 'shift'), @($folderLink, 'content'), @($folderLink, 'shift'))) {
        $pathview.Navigate([string] $directory)
        $paths = [string[]] @($case[0])
        $action = $createAction.Invoke($view, [object[]] @(,$paths))
        if ($action.Id -cne 'opencontaining' -or -not $action.IsEnabled) { throw 'Shortcut action ID or enabled state was incorrect.' }
        if ($case[1] -eq 'content') {
            $base = $factory.GetMethod('GetBaseMenu', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $createActions.Invoke($view, @())))
            try { $snapshot = $base.GetType().GetMethod('CaptureSnapshot', $instanceFlags).Invoke($base, @()) }
            finally { ([IDisposable] $base).Dispose() }
            $menu = $factory.GetMethod('GetContentMenuForContext', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $snapshot, $false, $null, $action))
        } else {
            $menu = $factory.GetMethod('GetItemMenuWithOpenLocation', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $null, $action))
        }
        try {
            Check-Menu $menu $true
            $allowRightButton = $menu.GetType().GetField('_allowRightButton', $instanceFlags).GetValue($menu)
            if ($allowRightButton -ne ($case[1] -eq 'shift')) { throw 'The native and paired menus did not preserve their right-button behavior.' }
            $null = $menu.GetType().GetMethod('ExecuteCommand', $instanceFlags).Invoke($menu, [object[]] @((Get-ActionCommandId $menu 'opencontaining')))
            if ($pathview.CurrentPath -cne $targetDirectory) { throw "The $($case[1]) action did not navigate: current=$($pathview.CurrentPath), target=$targetDirectory." }
        } finally { ([IDisposable] $menu).Dispose() }
    }
    $paths = [string[]] @($fileLink, $folderLink)
    $action = $createAction.Invoke($view, [object[]] @(,$paths))
    if ($action.IsEnabled) { throw 'Open file location was enabled for a multiple selection.' }
    $menu = $factory.GetMethod('GetItemMenuWithOpenLocation', $staticFlags).Invoke($null, [object[]] @($paths, $owner, $null, $action))
    try {
        Check-Menu $menu $false
        $null = $menu.GetType().GetMethod('ExecuteCommand', $instanceFlags).Invoke($menu, [object[]] @((Get-ActionCommandId $menu 'opencontaining')))
        if ($pathview.CurrentPath -cne $targetDirectory) { throw 'A disabled multiple-selection action navigated.' }
    } finally { ([IDisposable] $menu).Dispose() }
    if ($null -ne $createAction.Invoke($view, [object[]] @(,[string[]] @($file)))) { throw 'A regular file received a shortcut-only action.' }
    $pathview.Navigate([string] $directory)
    $action = $createAction.Invoke($view, [object[]] @(,[string[]] @($brokenLink)))
    $errorProbe = [SutShellPropertiesProbe]::new('Cannot open parent')
    try {
        $action.Invoke.Invoke()
        if (-not $errorProbe.Opened -or $pathview.CurrentPath -cne $directory) { throw 'A broken shortcut did not report an error without navigating.' }
    } finally { $errorProbe.Dispose() }
    $fixed = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true),
        [object[]] @([string] $directory, [bool] $false, $null, $null, $null, $null))
    $browseProbe = [OpenLocationBrowseProbe]::new()
    $event = $fixed.GetType().GetEvent('BrowseLocationRequested')
    $handler = { param($sender, $path, $first, $second, $third, $fourth) $browseProbe.Path = $path }.GetNewClosure()
    $delegate = [System.Management.Automation.LanguagePrimitives]::ConvertTo($handler, $event.EventHandlerType)
    $event.AddEventHandler($fixed, $delegate)
    $fixedView = $fixed.FindName('DirectoryContent')
    $action = $fixedView.GetType().GetMethod('CreateOpenLocationAction', $instanceFlags).Invoke($fixedView, [object[]] @(,[string[]] @($fileLink)))
    $action.Invoke.Invoke()
    if ($browseProbe.Path -cne $targetDirectory -or $fixed.CurrentPath -cne $directory) { throw 'A fixed Pathview did not request navigation in the browsable view.' }
    'Open file location tests passed.'
} finally {
    if ($null -ne $window) { $window.Close() }
    [Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    [IO.Directory]::Delete($directory, $true)
}