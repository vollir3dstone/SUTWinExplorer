$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public sealed class DragMouseProbe : IDisposable
{
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(NativePoint point);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string className, string title);
    public static IntPtr FindWindowByTitle(string title) => FindWindow(null, title);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    public static int[] WindowCenter(IntPtr window) { GetWindowRect(window, out var rect); return new[] { (rect.Left + rect.Right) / 2, (rect.Top + rect.Bottom) / 2 }; }
    private readonly int sourceX, sourceY, targetX, targetY;
    private readonly byte modifier;
    private readonly bool right;
    private readonly Timer timer;
    private int phase, busy;
    public bool Done;
    public string StartWindow;
    public DragMouseProbe(int sourceX, int sourceY, int targetX, int targetY, byte modifier, bool right)
    {
        this.sourceX = sourceX; this.sourceY = sourceY; this.targetX = targetX; this.targetY = targetY; this.modifier = modifier; this.right = right;
        timer = new Timer(Tick, null, 100, 150);
    }
    private void SetModifiers(bool release)
    {
        uint flags = release ? 2u : 0u;
        if (modifier == 0xFF) { keybd_event(0x11, 0, flags, UIntPtr.Zero); keybd_event(0x10, 0, flags, UIntPtr.Zero); }
        else if (modifier != 0) keybd_event(modifier, 0, flags, UIntPtr.Zero);
    }
    private void Tick(object state)
    {
        if (Interlocked.Exchange(ref busy, 1) != 0) return;
        try
        {
            switch (phase++)
            {
                case 0:
                    SetCursorPos(sourceX, sourceY);
                    var startWindow = WindowFromPoint(new NativePoint { X = sourceX, Y = sourceY });
                    var startName = new System.Text.StringBuilder(256);
                    GetWindowText(startWindow, startName, startName.Capacity);
                    StartWindow = startName.ToString();
                    SetModifiers(false);
                    mouse_event(right ? 8u : 2u, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 1: SetCursorPos(sourceX + 30, sourceY); mouse_event(1, 1, 0, 0, UIntPtr.Zero); break;
                case 2: SetCursorPos(targetX, targetY); mouse_event(1, 1, 0, 0, UIntPtr.Zero); break;
                case 3:
                    mouse_event(right ? 16u : 4u, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 10:
                    SetModifiers(true);
                    Done = true;
                    break;
            }
            if (phase > 40) { keybd_event(0x1B, 0, 0, UIntPtr.Zero); keybd_event(0x1B, 0, 2, UIntPtr.Zero); }
        }
        finally { Volatile.Write(ref busy, 0); }
    }
    public void Dispose() { timer.Dispose(); mouse_event(right ? 16u : 4u, 0, 0, 0, UIntPtr.Zero); SetModifiers(true); }
}
public sealed class RightMenuProbe : IDisposable
{
    private delegate bool EnumWindowProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr state);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentProcessId();
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    private readonly int x, y;
    private readonly IntPtr owner;
    private readonly Timer timer;
    private int phase, busy;
    public bool SeenBeforeRelease, Done;
    public RightMenuProbe(int x, int y, IntPtr owner) { this.x = x; this.y = y; this.owner = owner; timer = new Timer(Tick, null, 100, 150); }
    private void Tick(object state)
    {
        if (Interlocked.Exchange(ref busy, 1) != 0) return;
        try
        {
            if (phase++ == 0) { SetCursorPos(x, y); mouse_event(8, 0, 0, 0, UIntPtr.Zero); }
            else if (!SeenBeforeRelease && phase < 20)
            {
                EnumWindows((window, ignored) =>
                {
                    GetWindowThreadProcessId(window, out var process);
                    var name = new System.Text.StringBuilder(32);
                    GetClassName(window, name, name.Capacity);
                    if (process != GetCurrentProcessId() || name.ToString() != "#32768") return true;
                    SeenBeforeRelease = true;
                    PostMessage(owner, 0x001F, IntPtr.Zero, IntPtr.Zero);
                    return false;
                }, IntPtr.Zero);
            }
            else { mouse_event(16, 0, 0, 0, UIntPtr.Zero); Done = true; }
        }
        finally { Volatile.Write(ref busy, 0); }
    }
    public void Dispose() { timer.Dispose(); mouse_event(16, 0, 0, 0, UIntPtr.Zero); }
}
'@
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
$flags = [Reflection.BindingFlags]'Static,Instance,NonPublic'
$dragDrop = $assembly.GetType('SUTWinExplorer.ShellDragDrop', $true)
$root = Join-Path ([IO.Path]::GetTempPath()) ('SutDragDrop-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$destination = Join-Path $root 'destination'
[IO.Directory]::CreateDirectory($source) | Out-Null
[IO.Directory]::CreateDirectory($destination) | Out-Null
try {
    $driveRoot = [IO.Path]::GetPathRoot($source)
    $driveData = $dragDrop.GetMethod('CreateDataObject', $flags).Invoke($null, [object[]] @([string[]] @($driveRoot), [IntPtr]::Zero))
    if ([Runtime.InteropServices.Marshal]::IsComObject($driveData)) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($driveData) }
    foreach ($case in @(@('copy', 8, 1), @('move', 4, 2), @('link', 12, 4))) {
        $name, $keys, $expected = $case
        $file = [string] (Join-Path $source ($name + '.txt'))
        [IO.File]::WriteAllText($file, $name)
        $data = $dragDrop.GetMethod('CreateDataObject', $flags).Invoke($null, [object[]] @([string[]] @($file), [IntPtr]::Zero))
        $target = $dragDrop.GetMethod('CreateTarget', $flags).Invoke($null, [object[]] @([string] $destination, [IntPtr]::Zero))
        try {
            $type = $target.GetType()
            $effect = $type.GetMethod('Enter', $flags).Invoke($target, [object[]] @($data, [uint32] $keys, 0, 0, [uint32] 7))
            if ($effect -ne $expected) { throw "Unexpected $name drag effect: $effect." }
            $effect = $type.GetMethod('Over', $flags).Invoke($target, [object[]] @([uint32] $keys, 0, 0, [uint32] 7))
            if ($effect -ne $expected) { throw "Unexpected $name drag-over effect: $effect." }
        } finally {
            ([IDisposable] $target).Dispose()
            if ([Runtime.InteropServices.Marshal]::IsComObject($data)) { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($data) }
        }
    }
    [System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
    $application = [System.Windows.Application]::new()
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $resources = [System.Windows.Application]::LoadComponent([Uri]::new('/SUTWinExplorer;component/Styles/InputControlStyles.xaml', [UriKind]::Relative))
    $application.Resources.MergedDictionaries.Add($resources)
    $buttonStyle = [System.Windows.Style]::new([System.Windows.Controls.Button], $resources[[System.Windows.Controls.Button]])
    $buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::HeightProperty, [double] 24))
    $buttonStyle.Setters.Add([System.Windows.Setter]::new([System.Windows.FrameworkElement]::MinHeightProperty, [double] 24))
    $application.Resources['ContentPaneButtonStyle'] = $buttonStyle
    foreach ($key in @('ItemHoverBrush', 'ItemSelectionBrush', 'ItemSelectionBorderBrush', 'ItemRequestBrush')) { $application.Resources[$key] = [System.Windows.Media.Brushes]::LightGray }
    $application.Resources['ViewFrameBrush'] = [System.Windows.Media.Brushes]::LightGray
    $application.Resources['ViewFrameThickness'] = [System.Windows.Thickness]::new(1)
    $application.Resources['ShellIconTemplate'] = [System.Windows.DataTemplate]::new()
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext([System.Windows.Threading.DispatcherSynchronizationContext]::new())
    function Wait-Until([scriptblock] $condition, [string] $description) {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $deadline = [DateTime]::UtcNow.AddSeconds(12)
        $state = @{ Ready = $false }
        $timer.add_Tick({
            if (& $condition) { $state.Ready = $true; $frame.Continue = $false }
            elseif ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
        }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        if (-not $state.Ready) { throw "Timed out: $description." }
    }
    $window = [System.Windows.Window]::new()
    $window.Left = 40; $window.Top = 40; $window.Width = 1400; $window.Height = 600
    $grid = [System.Windows.Controls.Grid]::new()
    $grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $viewType = $assembly.GetType('SUTWinExplorer.ContentView', $true)
    $views = @(foreach ($path in @($source, $destination)) {
        $view = [Activator]::CreateInstance($viewType)
        $null = $viewType.GetMethod('Initialize', $flags).Invoke($view, @($false))
        $null = $viewType.GetMethod('SetCurrentPath', $flags).Invoke($view, @([string] $path))
        $view
    })
    [System.Windows.Controls.Grid]::SetColumn($views[1], 1)
    $null = $grid.Children.Add($views[0]); $null = $grid.Children.Add($views[1])
    $window.Content = $grid
    $window.Show(); $null = $window.Activate()
    try {
        $sourceFile = [string] (Join-Path $source 'mouse-copy.txt')
        [IO.File]::WriteAllText($sourceFile, 'mouse copy')
        $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($views[0], [object[]] @(,[string[]] @($sourceFile)))
        $null = $viewType.GetMethod('Refresh', $flags).Invoke($views[1], @($true))
        $sourceList = $views[0].FindName('FileList'); $targetList = $views[1].FindName('FileList')
        Wait-Until { $sourceList.SelectedItems.Count -eq 1 -and $null -ne $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0]) -and $targetList.IsVisible } 'drag test views'
        $sourceRow = $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0])
        $start = $sourceRow.PointToScreen([System.Windows.Point]::new(100, 10))
        $end = $targetList.PointToScreen([System.Windows.Point]::new(100, $targetList.ActualHeight - 20))
        $probe = [DragMouseProbe]::new([int] $start.X, [int] $start.Y, [int] $end.X, [int] $end.Y, 0x11, $false)
        try { Wait-Until { $probe.Done -and [IO.File]::Exists((Join-Path $destination 'mouse-copy.txt')) } 'mouse drag copy to table background' }
        finally { $probe.Dispose() }
        if (-not [IO.File]::Exists($sourceFile)) { throw 'Mouse copy removed its source.' }
        $folderTarget = [string] (Join-Path $destination 'target-folder')
        [IO.Directory]::CreateDirectory($folderTarget) | Out-Null
        $fileTarget = [string] (Join-Path $destination 'target-file.txt')
        [IO.File]::WriteAllText($fileTarget, 'target')
        $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($views[1], [object[]] @(,[string[]] @($folderTarget, $fileTarget)))
        $rowPath = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true).GetProperty('FullPath', $flags)
        function Get-TargetPoint([string] $path) {
            Wait-Until { @($targetList.Items | Where-Object { $rowPath.GetValue($_) -eq $path }).Count -eq 1 } "target row $path"
            $row = @($targetList.Items | Where-Object { $rowPath.GetValue($_) -eq $path })[0]
            $targetList.ScrollIntoView($row)
            Wait-Until { $null -ne $targetList.ItemContainerGenerator.ContainerFromItem($row) } "target row container $path"
            $targetList.ItemContainerGenerator.ContainerFromItem($row).PointToScreen([System.Windows.Point]::new(100, 10))
        }
        function Invoke-MouseDrag([string[]] $paths, [System.Windows.Point] $target, [byte] $modifier, [bool] $right) {
            $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($views[0], [object[]] @(,$paths))
            Wait-Until { $sourceList.SelectedItems.Count -eq $paths.Count -and $null -ne $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0]) } 'drag source rows'
            $sourceRow = $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0])
            $start = $sourceRow.PointToScreen([System.Windows.Point]::new(100, 10))
            $probe = [DragMouseProbe]::new([int] $start.X, [int] $start.Y, [int] $target.X, [int] $target.Y, $modifier, $right)
            try {
                Wait-Until { $probe.Done } 'mouse drag input'
            } finally { $probe.Dispose() }
        }
        $fileDrop = [string] (Join-Path $source 'file-row.txt')
        [IO.File]::WriteAllText($fileDrop, 'file row')
        Invoke-MouseDrag @($fileDrop) (Get-TargetPoint $fileTarget) 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $destination 'file-row.txt')) } 'copy onto file row'
        if ([IO.File]::ReadAllText($fileTarget) -cne 'target' -or -not [IO.File]::Exists($fileDrop)) { throw 'Dropping on a file row changed the target or source.' }
        $folderDrop = [string] (Join-Path $source 'folder-row.txt')
        [IO.File]::WriteAllText($folderDrop, 'folder row')
        Invoke-MouseDrag @($folderDrop) (Get-TargetPoint $folderTarget) 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'folder-row.txt')) } 'copy onto folder row'
        if (-not [IO.File]::Exists($folderDrop)) { throw 'Copy onto folder removed its source.' }
        $copyFirst = [string] (Join-Path $source 'copy-first.txt')
        $copySecond = [string] (Join-Path $source 'copy-second.txt')
        [IO.File]::WriteAllText($copyFirst, 'first'); [IO.File]::WriteAllText($copySecond, 'second')
        Invoke-MouseDrag @($copyFirst, $copySecond) (Get-TargetPoint $folderTarget) 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'copy-first.txt')) -and [IO.File]::Exists((Join-Path $folderTarget 'copy-second.txt')) } 'copy multiple selected items'
        if (-not [IO.File]::Exists($copyFirst) -or -not [IO.File]::Exists($copySecond)) { throw 'Multiple-item copy removed a source.' }
        $multiFirst = [string] (Join-Path $source 'multi-first.txt')
        $multiSecond = [string] (Join-Path $source 'multi-second.txt')
        [IO.File]::WriteAllText($multiFirst, 'first'); [IO.File]::WriteAllText($multiSecond, 'second')
        Invoke-MouseDrag @($multiFirst, $multiSecond) (Get-TargetPoint $folderTarget) 0 $false
        Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'multi-first.txt')) -and [IO.File]::Exists((Join-Path $folderTarget 'multi-second.txt')) } 'move multiple selected items'
        if ([IO.File]::Exists($multiFirst) -or [IO.File]::Exists($multiSecond)) { throw 'Multiple-item move left a source behind.' }
        $linkDrop = [string] (Join-Path $source 'mouse-link.txt')
        [IO.File]::WriteAllText($linkDrop, 'mouse link')
        Invoke-MouseDrag @($linkDrop) (Get-TargetPoint $folderTarget) 0xFF $false
        Wait-Until { @([IO.Directory]::GetFiles($folderTarget, '*mouse-link*.lnk')).Count -eq 1 } 'mouse drag link'
        if (-not [IO.File]::Exists($linkDrop) -or [IO.File]::Exists((Join-Path $folderTarget 'mouse-link.txt'))) { throw 'Link drop changed or copied the source.' }
        function Start-ExternalProbe([string] $mode, [string] $path, [string] $result) {
            $title = 'SutDragProbe-' + [Guid]::NewGuid().ToString('N')
            $startInfo = [Diagnostics.ProcessStartInfo]::new('pwsh')
            $startInfo.UseShellExecute = $false
            foreach ($argument in @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'DragDropExternalProbe.ps1'), '-Title', $title, '-Path', $path, '-Mode', $mode, '-ResultPath', $result)) { $startInfo.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::Start($startInfo)
            try {
                Wait-Until ({ ([IO.File]::Exists($result + '.ready') -and [DragMouseProbe]::FindWindowByTitle($title) -ne [IntPtr]::Zero) -or $process.HasExited }.GetNewClosure()) "external $mode window"
                if ($process.HasExited) { throw "External $mode probe exited early with code $($process.ExitCode)." }
                return @($process, [DragMouseProbe]::WindowCenter([DragMouseProbe]::FindWindowByTitle($title)))
            } catch { if (-not $process.HasExited) { $process.Kill() }; throw }
        }
        $externalFile = [string] (Join-Path $source 'external-source.txt')
        [IO.File]::WriteAllText($externalFile, 'external source')
        foreach ($mode in @('source', 'text', 'right-source')) {
            $result = Join-Path $root ("$mode-result.txt")
            $external = Start-ExternalProbe $mode $externalFile $result
            $process = $external[0]; $position = $external[1]
            try {
                $end = Get-TargetPoint $folderTarget
                $probe = [DragMouseProbe]::new($position[0], $position[1], [int] $end.X, [int] $end.Y, 0, ($mode -eq 'right-source'))
                try { Wait-Until { $probe.Done -and ([IO.File]::Exists($result) -or $process.HasExited) } "external $mode drag" }
                catch { throw "External $mode drag stalled: done=$($probe.Done), started=$([IO.File]::Exists($result + '.started')), result=$([IO.File]::Exists($result)), exited=$($process.HasExited), position=$($position -join ','), window=$($probe.StartWindow)." }
                finally { $probe.Dispose() }
                if (-not [IO.File]::Exists($result)) { throw "External $mode probe exited without a result: code=$($process.ExitCode)." }
                $expected = if ($mode -eq 'source') { 'Copy' } else { 'None' }
                if ([IO.File]::ReadAllText($result) -ne $expected) { throw "Unexpected external $mode drag effect." }
                if ($mode -eq 'source' -and (-not [IO.File]::Exists((Join-Path $folderTarget 'external-source.txt')) -or -not [IO.File]::Exists($externalFile))) { throw 'External file copy failed.' }
            } finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        }
        $externalDestination = [string] (Join-Path $root 'external-destination')
        [IO.Directory]::CreateDirectory($externalDestination) | Out-Null
        $outgoingFile = [string] (Join-Path $source 'external-target.txt')
        [IO.File]::WriteAllText($outgoingFile, 'external target')
        $result = Join-Path $root 'target-result.txt'
        $external = Start-ExternalProbe 'target' $externalDestination $result
        $process = $external[0]; $position = $external[1]
        try {
            Invoke-MouseDrag @($outgoingFile) ([System.Windows.Point]::new($position[0], $position[1])) 0 $false
            Wait-Until { [IO.File]::Exists($result) -and [IO.File]::Exists((Join-Path $externalDestination 'external-target.txt')) } 'drag to external target'
            if (-not [IO.File]::Exists($outgoingFile)) { throw 'External target copy removed its source.' }
        } finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }
        $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($views[0], [object[]] @(,[string[]] @($outgoingFile)))
        Wait-Until { $sourceList.SelectedItems.Count -eq 1 -and $null -ne $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0]) } 'right-click target row'
        $sourceRow = $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0])
        $point = $sourceRow.PointToScreen([System.Windows.Point]::new(100, 10))
        $owner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $menuProbe = [RightMenuProbe]::new([int] $point.X, [int] $point.Y, $owner)
        try {
            Wait-Until { $menuProbe.Done } 'right-click menu'
            if (-not $menuProbe.SeenBeforeRelease) { throw 'The context menu did not open on right-button down.' }
        } finally { $menuProbe.Dispose() }
    } finally {
        $window.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    'Shell drag-and-drop tests passed.'
} finally {
    [IO.Directory]::Delete($root, $true)
}