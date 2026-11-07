param([ValidateSet('All', 'Native', 'Interactions', 'Feedback', 'Explorer')] [string] $Suite = 'All')
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
    private readonly int sourceX, sourceY, targetX, targetY, middleX, middleY;
    private readonly byte modifier;
    private readonly bool right, clickOnly, hasMiddle;
    private bool holdAtTarget;
    private readonly Timer timer;
    private int phase, busy;
    public bool Done;
    public bool AtTarget, Continue;
    public string StartWindow;
    public DragMouseProbe(int sourceX, int sourceY, int targetX, int targetY, byte modifier, bool right)
        : this(sourceX, sourceY, targetX, targetY, modifier, right, false) { }
    public DragMouseProbe(int sourceX, int sourceY, int middleX, int middleY, int targetX, int targetY, byte modifier, bool useMiddle)
        : this(sourceX, sourceY, targetX, targetY, modifier, false, false) { this.middleX = middleX; this.middleY = middleY; hasMiddle = useMiddle; }
    public DragMouseProbe(int sourceX, int sourceY, int targetX, int targetY, byte modifier, bool right, bool clickOnly, bool holdAtTarget)
        : this(sourceX, sourceY, targetX, targetY, modifier, right, clickOnly) { this.holdAtTarget = holdAtTarget; }
    public DragMouseProbe(int sourceX, int sourceY, int targetX, int targetY, byte modifier, bool right, bool clickOnly)
    {
        this.sourceX = sourceX; this.sourceY = sourceY; this.targetX = targetX; this.targetY = targetY; this.modifier = modifier; this.right = right; this.clickOnly = clickOnly;
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
                case 1: if (clickOnly) mouse_event(right ? 16u : 4u, 0, 0, 0, UIntPtr.Zero); else { SetCursorPos(sourceX + 30, sourceY); mouse_event(1, 1, 0, 0, UIntPtr.Zero); } break;
                case 2: if (!clickOnly) { SetCursorPos(hasMiddle ? middleX : targetX, hasMiddle ? middleY : targetY); mouse_event(1, 1, 0, 0, UIntPtr.Zero); AtTarget = true; } break;
                case 3:
                    if (holdAtTarget && !Continue) { phase--; break; }
                    if (hasMiddle) { SetCursorPos(targetX, targetY); mouse_event(1, 1, 0, 0, UIntPtr.Zero); }
                    else mouse_event(right ? 16u : 4u, 0, 0, 0, UIntPtr.Zero);
                    break;
                case 4: if (hasMiddle) mouse_event(right ? 16u : 4u, 0, 0, 0, UIntPtr.Zero); break;
                case 10:
                    SetModifiers(true);
                    Done = true;
                    break;
            }
            if (phase > 40) { keybd_event(0x1B, 0, 0, UIntPtr.Zero); keybd_event(0x1B, 0, 2, UIntPtr.Zero); }
        }
        finally { Volatile.Write(ref busy, 0); }
    }
    public void Dispose() { timer.Dispose(); if (!Done) mouse_event(right ? 16u : 4u, 0, 0, 0, UIntPtr.Zero); SetModifiers(true); }
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
    private readonly bool checkAfterRelease;
    private readonly Timer timer;
    private int phase, busy;
    public bool MenuSeen, Done;
    public RightMenuProbe(int x, int y, IntPtr owner) : this(x, y, owner, false) { }
    public RightMenuProbe(int x, int y, IntPtr owner, bool checkAfterRelease) { this.x = x; this.y = y; this.owner = owner; this.checkAfterRelease = checkAfterRelease; timer = new Timer(Tick, null, 100, 150); }
    private void Tick(object state)
    {
        if (Interlocked.Exchange(ref busy, 1) != 0) return;
        try
        {
            if (phase++ == 0) { SetCursorPos(x, y); mouse_event(8, 0, 0, 0, UIntPtr.Zero); }
            else if (checkAfterRelease && phase == 2) { mouse_event(16, 0, 0, 0, UIntPtr.Zero); }
            else if (!MenuSeen && phase < 20)
            {
                EnumWindows((window, ignored) =>
                {
                    GetWindowThreadProcessId(window, out var process);
                    var name = new System.Text.StringBuilder(32);
                    GetClassName(window, name, name.Capacity);
                    if (process != GetCurrentProcessId() || name.ToString() != "#32768") return true;
                    MenuSeen = true;
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
$traceWriter = [IO.StringWriter]::new()
$traceListener = [Diagnostics.TextWriterTraceListener]::new($traceWriter)
$null = [Diagnostics.Trace]::Listeners.Add($traceListener)
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
    if ($Suite -eq 'Native') {
        'Shell drag-and-drop native tests passed.'
        return
    }
    [System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
    $application = [System.Windows.Application]::new()
    $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $resources = [System.Windows.Application]::LoadComponent([Uri]::new('/SUTWinExplorer;component/sources/InputControlStyles.xaml', [UriKind]::Relative))
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
        if ($Suite -in @('All', 'Interactions')) {
            $sourceRow = $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0])
            $start = $sourceRow.PointToScreen([System.Windows.Point]::new(100, 10))
            $end = $targetList.PointToScreen([System.Windows.Point]::new(100, $targetList.ActualHeight - 20))
            $probe = [DragMouseProbe]::new([int] $start.X, [int] $start.Y, [int] $end.X, [int] $end.Y, 0x11, $false)
            try { Wait-Until { $probe.Done -and [IO.File]::Exists((Join-Path $destination 'mouse-copy.txt')) } 'mouse drag copy to table background' }
            finally { $probe.Dispose() }
            if (-not [IO.File]::Exists($sourceFile)) { throw 'Mouse copy removed its source.' }
        }
        $folderTarget = [string] (Join-Path $destination 'target-folder')
        [IO.Directory]::CreateDirectory($folderTarget) | Out-Null
        $fileTarget = [string] (Join-Path $destination 'target-file.txt')
        [IO.File]::WriteAllText($fileTarget, 'target')
        $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($views[1], [object[]] @(,[string[]] @($folderTarget, $fileTarget)))
        $rowPath = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true).GetProperty('FullPath')
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
        function Assert-BackgroundRejectsMoveAndLink([string] $name, [System.Windows.Point] $point, [string] $targetDirectory = $destination) {
            foreach ($modifier in @(0, 0x10, 0xFF)) {
                $fileName = "rejected-$name-$modifier.txt"
                $file = [string] (Join-Path $source $fileName)
                [IO.File]::WriteAllText($file, 'rejected')
                Invoke-MouseDrag @($file) $point $modifier $false
                if (-not [IO.File]::Exists($file) -or [IO.File]::Exists((Join-Path $targetDirectory $fileName)) -or @([IO.Directory]::GetFiles($targetDirectory, "*rejected-$name-$modifier*.lnk")).Count -ne 0) { throw "$name accepted modifier $modifier." }
                [IO.File]::Delete($file)
            }
        }
        if ($Suite -in @('All', 'Interactions')) {
        $fileDrop = [string] (Join-Path $source 'file-row.txt')
        [IO.File]::WriteAllText($fileDrop, 'file row')
        Invoke-MouseDrag @($fileDrop) (Get-TargetPoint $fileTarget) 0x11 $false
        if ([IO.File]::Exists((Join-Path $destination 'file-row.txt')) -or [IO.File]::ReadAllText($fileTarget) -cne 'target' -or -not [IO.File]::Exists($fileDrop)) { throw 'File row accepted a copy or changed the source or target.' }
        [IO.File]::Delete($fileDrop)
        Assert-BackgroundRejectsMoveAndLink 'file-row' (Get-TargetPoint $fileTarget)
        Assert-BackgroundRejectsMoveAndLink 'table-background' ($targetList.PointToScreen([System.Windows.Point]::new(100, $targetList.ActualHeight - 20)))
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
        Assert-BackgroundRejectsMoveAndLink 'folder-row' (Get-TargetPoint $folderTarget) $folderTarget
        }
        function Stop-ExternalProbe([Diagnostics.Process] $process) {
            try {
                if (-not $process.WaitForExit(2000)) {
                    $null = $process.CloseMainWindow()
                    if (-not $process.WaitForExit(5000)) {
                        $process.Kill()
                        $process.WaitForExit()
                        throw 'External drag probe did not exit after its window was closed.'
                    }
                }
                if ($process.ExitCode -ne 0) { throw "External drag probe exited with code $($process.ExitCode)." }
            } finally { $process.Dispose() }
        }
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
            } catch { Stop-ExternalProbe $process; throw }
        }
        $externalFile = [string] (Join-Path $source 'external-source.txt')
        [IO.File]::WriteAllText($externalFile, 'external source')
        if ($Suite -in @('All', 'Interactions')) {
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
            } finally { Stop-ExternalProbe $process }
        }
        }
        if ($Suite -in @('All', 'Feedback')) {
        foreach ($case in @(@('copy', 0x11, 'Copy', 'folder'), @('folder-default', 0, 'None', 'folder'), @('folder-move', 0x10, 'None', 'folder'), @('folder-link', 0xFF, 'None', 'folder'), @('file-copy', 0x11, 'None', 'file'), @('reject-default', 0, 'None', 'background'), @('reject-move', 0x10, 'None', 'background'), @('reject-link', 0xFF, 'None', 'background'))) {
            $null = $traceWriter.GetStringBuilder().Clear()
            $name, $modifier, $expected, $targetKind = $case
            $feedbackFile = [string] (Join-Path $source "external-feedback-$name.txt")
            [IO.File]::WriteAllText($feedbackFile, $name)
            $result = Join-Path $root "feedback-$name.txt"
            $external = Start-ExternalProbe 'source-all' $feedbackFile $result
            $process = $external[0]; $position = $external[1]
            try {
                $end = if ($targetKind -eq 'folder') { Get-TargetPoint $folderTarget } elseif ($targetKind -eq 'file') { Get-TargetPoint $fileTarget } else { $targetList.PointToScreen([System.Windows.Point]::new(100, $targetList.ActualHeight - 20)) }
                $probe = [DragMouseProbe]::new($position[0], $position[1], [int] $end.X, [int] $end.Y, $modifier, $false)
                try { Wait-Until { $probe.Done -and [IO.File]::Exists($result) } "external feedback $name" }
                finally { $probe.Dispose() }
                $feedback = [IO.File]::ReadAllText($result + '.feedback')
                $effect = [IO.File]::ReadAllText($result)
                $description = [IO.File]::ReadAllText($result + '.feedback.description')
                $traceListener.Flush()
                if ($traceWriter.ToString() -match 'Drag image (update|drop|cleanup) failed') { throw "External $name drag-image manager failed: $traceWriter" }
                if ($feedback -ne $expected) { throw "External $name feedback=$feedback, expected=$expected, drop=$effect." }
                $expectedDescription = @{ None = '0:Cannot drop here'; Copy = '1:Copy'; Move = '2:Move'; Link = '3:Create shortcut' }[$expected]
                if ($name -in @('folder-default', 'folder-move', 'reject-default', 'reject-move')) { $expectedDescription = '0:Cannot move here' }
                if ($description -ne $expectedDescription) { throw "External $name description=$description, expected=$expectedDescription." }
                $targetFile = Join-Path $folderTarget ([IO.Path]::GetFileName($feedbackFile))
                if ($name -eq 'copy') { Wait-Until { [IO.File]::Exists($targetFile) -and [IO.File]::Exists($feedbackFile) } 'external feedback copy' }
                elseif ($effect -ne 'None' -or -not [IO.File]::Exists($feedbackFile) -or [IO.File]::Exists($targetFile) -or [IO.File]::Exists((Join-Path $destination ([IO.Path]::GetFileName($feedbackFile)))) -or @([IO.Directory]::GetFiles($destination, "*$name*.lnk")).Count -ne 0 -or @([IO.Directory]::GetFiles($folderTarget, "*$name*.lnk")).Count -ne 0) { throw "External $name was not rejected." }
            } finally { Stop-ExternalProbe $process }
        }
        $feedbackFile = [string] (Join-Path $source 'external-feedback-transition.txt')
        [IO.File]::WriteAllText($feedbackFile, 'transition')
        $result = Join-Path $root 'feedback-transition.txt'
        $external = Start-ExternalProbe 'source-all' $feedbackFile $result
        $process = $external[0]; $position = $external[1]
        try {
            $middle = Get-TargetPoint $folderTarget
            $end = Get-TargetPoint $fileTarget
            $probe = [DragMouseProbe]::new($position[0], $position[1], [int] $middle.X, [int] $middle.Y, [int] $end.X, [int] $end.Y, 0x11, $true)
            try { Wait-Until { $probe.Done -and [IO.File]::Exists($result) } 'external feedback transition' }
            finally { $probe.Dispose() }
            $history = [IO.File]::ReadAllText($result + '.feedback.history')
            if ($history -notmatch '(?s)Copy\|1:Copy.*None\|0:Cannot drop here') { throw "External transition feedback did not change from Copy to forbidden: $history" }
            if ([IO.File]::ReadAllText($result) -ne 'None' -or -not [IO.File]::Exists($feedbackFile) -or [IO.File]::Exists((Join-Path $destination 'external-feedback-transition.txt'))) { throw 'External transition drop was not rejected.' }
        } finally { Stop-ExternalProbe $process }
        }
        $owner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        if ($Suite -in @('All', 'Interactions')) {
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
        } finally { Stop-ExternalProbe $process }
        $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($views[0], [object[]] @(,[string[]] @($outgoingFile)))
        Wait-Until { $sourceList.SelectedItems.Count -eq 1 -and $null -ne $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0]) } 'right-click target row'
        $sourceRow = $sourceList.ItemContainerGenerator.ContainerFromItem($sourceList.SelectedItems[0])
        $point = $sourceRow.PointToScreen([System.Windows.Point]::new(100, 10))
        $owner = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        $menuProbe = [RightMenuProbe]::new([int] $point.X, [int] $point.Y, $owner)
        try {
            Wait-Until { $menuProbe.Done } 'right-click menu'
            if (-not $menuProbe.MenuSeen) { throw 'The context menu did not open on right-button down.' }
        } finally { $menuProbe.Dispose() }
        }

        $sidebarSource = [string] (Join-Path $destination 'sidebar-source')
        [IO.Directory]::CreateDirectory($sidebarSource) | Out-Null
        [IO.File]::WriteAllText((Join-Path $sidebarSource 'nested.txt'), 'sidebar')
        $pathview = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.Pathview', $true),
            [object[]] @([string] $destination, [bool] $false, $null, $null, $null, $null))
        $navigation = @{ Paths = [Collections.Generic.List[string]]::new() }
        $pathview.add_BrowseLocationRequested({ param($view, $path, $fixed, $siblings, $internalDirectories, $internalContent) $navigation.Paths.Add($path) }.GetNewClosure())
        $grid.Children.Remove($views[1])
        [System.Windows.Controls.Grid]::SetColumn($pathview, 1)
        $null = $grid.Children.Add($pathview)
        $sidebar = $pathview.FindName('ActivePathSubdirectoriesList')
        Wait-Until { $sidebar.IsVisible -and @($sidebar.Items | Where-Object { $_.Path -eq $sidebarSource }).Count -eq 1 } 'sidebar drag test view'
        if (-not $sidebar.AllowDrop -or $pathview.FindName('ActivePathTree').AllowDrop -or -not $pathview.FindName('ActivePathAndSiblingsTree').AllowDrop) { throw 'Drag-and-drop was enabled on the wrong sidebar controls.' }
        if ($Suite -in @('All', 'Interactions')) {
        foreach ($targetName in @('LocationLabel', 'LocationBaseIcon')) {
            $backgroundFile = [string] (Join-Path $source ("pathview-$targetName.txt"))
            [IO.File]::WriteAllText($backgroundFile, $targetName)
            $target = $pathview.FindName($targetName)
            $point = $target.PointToScreen([System.Windows.Point]::new($target.ActualWidth / 2, $target.ActualHeight / 2))
            Invoke-MouseDrag @($backgroundFile) $point 0x11 $false
            Wait-Until { [IO.File]::Exists((Join-Path $destination ("pathview-$targetName.txt"))) } "copy onto $targetName background"
            if (-not [IO.File]::Exists($backgroundFile)) { throw "Copy onto $targetName removed its source." }
        }
        }
        $target = $pathview.FindName('LocationLabel')
        $point = $target.PointToScreen([System.Windows.Point]::new($target.ActualWidth / 2, $target.ActualHeight / 2))
        if ($Suite -in @('All', 'Interactions')) { Assert-BackgroundRejectsMoveAndLink 'pathview-background' $point }
        if ($Suite -in @('All', 'Feedback')) {
        foreach ($case in @(@('copy', 0x11, 'Copy'), @('default', 0, 'None'), @('move', 0x10, 'None'), @('link', 0xFF, 'None'))) {
            $null = $traceWriter.GetStringBuilder().Clear()
            $name, $modifier, $expected = $case
            $feedbackFile = [string] (Join-Path $source "external-pathview-$name.txt")
            [IO.File]::WriteAllText($feedbackFile, $name)
            $result = Join-Path $root "pathview-feedback-$name.txt"
            $external = Start-ExternalProbe 'source-all' $feedbackFile $result
            $process = $external[0]; $position = $external[1]
            try {
                $probe = [DragMouseProbe]::new($position[0], $position[1], [int] $point.X, [int] $point.Y, $modifier, $false)
                try { Wait-Until { $probe.Done -and [IO.File]::Exists($result) } "external Pathview feedback $name" }
                finally { $probe.Dispose() }
                $feedback = [IO.File]::ReadAllText($result + '.feedback')
                $description = [IO.File]::ReadAllText($result + '.feedback.description')
                $traceListener.Flush()
                if ($traceWriter.ToString() -match 'Drag image (update|drop|cleanup) failed') { throw "External Pathview $name drag-image manager failed: $traceWriter" }
                if ($feedback -ne $expected) { throw "External Pathview $name feedback=$feedback, expected=$expected." }
                $expectedDescription = @{ None = '0:Cannot drop here'; Copy = '1:Copy'; Move = '2:Move'; Link = '3:Create shortcut' }[$expected]
                if ($name -in @('default', 'move')) { $expectedDescription = '0:Cannot move here' }
                if ($description -ne $expectedDescription) { throw "External Pathview $name description=$description, expected=$expectedDescription." }
                $targetFile = Join-Path $destination ([IO.Path]::GetFileName($feedbackFile))
                if ($name -eq 'copy') { Wait-Until { [IO.File]::Exists($targetFile) -and [IO.File]::Exists($feedbackFile) } 'external Pathview copy' }
                elseif ([IO.File]::ReadAllText($result) -ne 'None' -or -not [IO.File]::Exists($feedbackFile) -or [IO.File]::Exists($targetFile) -or @([IO.Directory]::GetFiles($destination, "*external-pathview-$name*.lnk")).Count -ne 0) { throw "External Pathview $name was not rejected." }
            } finally { Stop-ExternalProbe $process }
        }
        }
        if ($Suite -eq 'Explorer') {
            Add-Type -AssemblyName UIAutomationClient
            Add-Type -AssemblyName UIAutomationTypes
            Add-Type -AssemblyName System.Drawing
            $explorerFile = [string] (Join-Path $source 'explorer-feedback.txt')
            [IO.File]::WriteAllText($explorerFile, 'explorer feedback')
            $shell = New-Object -ComObject Shell.Application
            $existingWindows = @($shell.Windows() | ForEach-Object { $_.HWND })
            $shell.Open($source)
            $explorer = $null
            try {
                Wait-Until { $script:explorer = @($shell.Windows() | Where-Object { $_.HWND -notin $existingWindows -and $_.Document.Folder.Self.Path -eq $source }) | Select-Object -First 1; $null -ne $script:explorer } 'Explorer source window'
                $explorer = $script:explorer
                $explorer.Left = 50; $explorer.Top = 60; $explorer.Width = 500; $explorer.Height = 500
                $explorer.Document.SelectItem($explorer.Document.Folder.ParseName('explorer-feedback.txt'), 29)
                $rootElement = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $explorer.HWND)
                $itemCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'explorer-feedback.txt')
                $item = $null
                Wait-Until { $script:item = $rootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $itemCondition); $null -ne $script:item -and -not $script:item.Current.IsOffscreen } 'Explorer source item'
                $item = $script:item
                $rectangle = $item.Current.BoundingRectangle
                $observed = @{ Seen = $false; Effect = ''; Allowed = ''; Keys = '' }
                $handler = [System.Windows.DragEventHandler] { param($sender, $eventArgs) $observed.Seen = $true; $observed.Effect = $eventArgs.Effects.ToString(); $observed.Allowed = $eventArgs.AllowedEffects.ToString(); $observed.Keys = $eventArgs.KeyStates.ToString() }.GetNewClosure()
                $pathview.AddHandler([System.Windows.DragDrop]::PreviewDragOverEvent, $handler, $true)
                $probe = [DragMouseProbe]::new([int] ($rectangle.X + [Math]::Min(60, $rectangle.Width / 2)), [int] ($rectangle.Y + $rectangle.Height / 2), [int] $point.X, [int] $point.Y, 0, $false, $false, $true)
                try {
                    try { Wait-Until { $probe.AtTarget -and $observed.Seen } 'Explorer drag over Pathview background' }
                    catch { throw "Explorer drag did not reach Pathview: start=$($rectangle.X),$($rectangle.Y),$($rectangle.Width),$($rectangle.Height), target=$point, startWindow=$($probe.StartWindow), atTarget=$($probe.AtTarget), seen=$($observed.Seen)." }
                    $imagePath = Join-Path $PSScriptRoot '../artifacts/explorer-drag-feedback.png'
                    $image = [System.Drawing.Bitmap]::new(360, 180)
                    $graphics = [System.Drawing.Graphics]::FromImage($image)
                    try {
                        $graphics.CopyFromScreen([int] $point.X - 30, [int] $point.Y - 35, 0, 0, $image.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
                        $image.Save($imagePath, [System.Drawing.Imaging.ImageFormat]::Png)
                    } finally { $graphics.Dispose(); $image.Dispose() }
                    "Explorer hover: effect=$($observed.Effect), allowed=$($observed.Allowed), keys=$($observed.Keys), screenshot=$imagePath"
                    $probe.Continue = $true
                    Wait-Until { $probe.Done } 'Explorer drag completion'
                    if ($observed.Effect -ne 'None' -or -not [IO.File]::Exists($explorerFile) -or [IO.File]::Exists((Join-Path $destination 'explorer-feedback.txt'))) { throw 'Explorer default move was not rejected.' }
                } finally { $probe.Dispose(); $pathview.RemoveHandler([System.Windows.DragDrop]::PreviewDragOverEvent, $handler) }
            } finally { if ($null -ne $explorer) { $explorer.Quit() } }
        }
        if ($Suite -in @('All', 'Interactions')) {
        $buttonFile = [string] (Join-Path $source 'excluded-button.txt')
        [IO.File]::WriteAllText($buttonFile, 'excluded')
        $button = $pathview.FindName('OpenInExplorerButton')
        $point = $button.PointToScreen([System.Windows.Point]::new($button.ActualWidth / 2, $button.ActualHeight / 2))
        Invoke-MouseDrag @($buttonFile) $point 0x11 $false
        if ([IO.File]::Exists((Join-Path $destination 'excluded-button.txt')) -or -not [IO.File]::Exists($buttonFile)) { throw 'The button accepted a Pathview background drop.' }
        $pathviewContent = $pathview.FindName('DirectoryContent')
        $pathviewList = $pathviewContent.FindName('FileList')
        $null = $viewType.GetMethod('RevealInsertedItems', $flags).Invoke($pathviewContent, [object[]] @(,[string[]] @($folderTarget)))
        Wait-Until { $pathviewList.IsVisible -and @($pathviewList.Items | Where-Object { $rowPath.GetValue($_) -eq $folderTarget }).Count -eq 1 } 'Pathview table folder row'
        $folderRow = @($pathviewList.Items | Where-Object { $rowPath.GetValue($_) -eq $folderTarget })[0]
        $pathviewList.ScrollIntoView($folderRow)
        Wait-Until { $null -ne $pathviewList.ItemContainerGenerator.ContainerFromItem($folderRow) } 'Pathview table folder container'
        $point = $pathviewList.ItemContainerGenerator.ContainerFromItem($folderRow).PointToScreen([System.Windows.Point]::new(100, 10))
        $tableFile = [string] (Join-Path $source 'pathview-table-row.txt')
        [IO.File]::WriteAllText($tableFile, 'table row')
        Invoke-MouseDrag @($tableFile) $point 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'pathview-table-row.txt')) } 'copy onto Pathview table folder row'
        if ([IO.File]::Exists((Join-Path $destination 'pathview-table-row.txt')) -or -not [IO.File]::Exists($tableFile)) { throw 'Pathview background intercepted the table folder drop.' }
        $excludedFile = [string] (Join-Path $source 'excluded-tree.txt')
        [IO.File]::WriteAllText($excludedFile, 'excluded')
        $activeTree = $pathview.FindName('ActivePathTree')
        Wait-Until { $null -ne $activeTree.ItemContainerGenerator.ContainerFromIndex(0) } 'active path tree row'
        $point = $activeTree.ItemContainerGenerator.ContainerFromIndex(0).PointToScreen([System.Windows.Point]::new(60, 10))
        Invoke-MouseDrag @($excludedFile) $point 0x11 $false
        if ([IO.File]::Exists((Join-Path $destination 'excluded-tree.txt')) -or -not [IO.File]::Exists($excludedFile)) { throw 'The tree accepted a Pathview background drop.' }
        if ($navigation.Paths.Count -ne 0) { throw "Dropping on the active path tree triggered navigation: $($navigation.Paths -join ',')." }
        $menuProbe = [RightMenuProbe]::new([int] $point.X, [int] $point.Y, $owner, $true)
        try {
            Wait-Until { $menuProbe.Done } 'active path tree right-click'
            if ($menuProbe.MenuSeen) { throw 'The active path tree unexpectedly opened a context menu.' }
        } finally { $menuProbe.Dispose() }
        if ($navigation.Paths.Count -ne 0) { throw "Tree right-click triggered navigation: $($navigation.Paths -join ',')." }
        function Get-SidebarPoint([string] $path) {
            Wait-Until { @($sidebar.Items | Where-Object { $_.Path -eq $path }).Count -eq 1 } "sidebar row $path"
            $item = @($sidebar.Items | Where-Object { $_.Path -eq $path })[0]
            $sidebar.ScrollIntoView($item)
            Wait-Until { $null -ne $sidebar.ItemContainerGenerator.ContainerFromItem($item) } "sidebar row container $path"
            $sidebar.ItemContainerGenerator.ContainerFromItem($item).PointToScreen([System.Windows.Point]::new(60, 10))
        }
        $sidebarFile = [string] (Join-Path $source 'sidebar-row.txt')
        [IO.File]::WriteAllText($sidebarFile, 'sidebar row')
        Invoke-MouseDrag @($sidebarFile) (Get-SidebarPoint $folderTarget) 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'sidebar-row.txt')) } 'copy onto sidebar folder row'
        if ($navigation.Paths.Count -ne 0) { throw "Dropping on sidebar row triggered navigation: $($navigation.Paths -join ',')." }
        $backgroundFile = [string] (Join-Path $source 'sidebar-background.txt')
        [IO.File]::WriteAllText($backgroundFile, 'sidebar background')
        $backgroundPoint = $sidebar.PointToScreen([System.Windows.Point]::new(60, $sidebar.ActualHeight - 20))
        Invoke-MouseDrag @($backgroundFile) $backgroundPoint 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $destination 'sidebar-background.txt')) } 'copy onto sidebar background'
        Assert-BackgroundRejectsMoveAndLink 'sidebar-background' $backgroundPoint
        Assert-BackgroundRejectsMoveAndLink 'sidebar-row' (Get-SidebarPoint $folderTarget) $folderTarget
        $start = Get-SidebarPoint $sidebarSource
        $end = $sourceList.PointToScreen([System.Windows.Point]::new(100, $sourceList.ActualHeight - 20))
        $sidebar.SelectedItem = @($sidebar.Items | Where-Object { $_.Path -eq $folderTarget })[0]
        $probe = [DragMouseProbe]::new([int] $start.X, [int] $start.Y, [int] $end.X, [int] $end.Y, 0x11, $false)
        try { Wait-Until { $probe.Done -and [IO.File]::Exists((Join-Path $source 'sidebar-source/nested.txt')) } 'drag clicked sidebar folder to table' }
        finally { $probe.Dispose() }
        if ([IO.Directory]::Exists((Join-Path $source 'target-folder')) -or $navigation.Paths.Count -ne 0) { throw "Sidebar drag used selection=$([IO.Directory]::Exists((Join-Path $source 'target-folder'))) or triggered navigation=$($navigation.Paths -join ',')." }
        $sidebarExternalDestination = [string] (Join-Path $root 'sidebar-external-destination')
        [IO.Directory]::CreateDirectory($sidebarExternalDestination) | Out-Null
        $result = Join-Path $root 'sidebar-target-result.txt'
        $external = Start-ExternalProbe 'target' $sidebarExternalDestination $result
        $process = $external[0]; $position = $external[1]
        try {
            $start = Get-SidebarPoint $sidebarSource
            $probe = [DragMouseProbe]::new([int] $start.X, [int] $start.Y, $position[0], $position[1], 0, $false)
            try { Wait-Until { $probe.Done -and [IO.File]::Exists($result) -and [IO.File]::Exists((Join-Path $sidebarExternalDestination 'sidebar-source/nested.txt')) } 'drag sidebar folder to external target' }
            finally { $probe.Dispose() }
            if (-not [IO.Directory]::Exists($sidebarSource) -or $navigation.Paths.Count -ne 0) { throw 'External sidebar copy removed its source or triggered navigation.' }
        } finally { Stop-ExternalProbe $process }
        foreach ($mode in @('source', 'text', 'right-source')) {
            $result = Join-Path $root ("sidebar-$mode-result.txt")
            $external = Start-ExternalProbe $mode $externalFile $result
            $process = $external[0]; $position = $external[1]
            try {
                $end = Get-SidebarPoint $sidebarSource
                $probe = [DragMouseProbe]::new($position[0], $position[1], [int] $end.X, [int] $end.Y, 0, ($mode -eq 'right-source'))
                try { Wait-Until { $probe.Done -and ([IO.File]::Exists($result) -or $process.HasExited) } "external $mode drag to sidebar" }
                finally { $probe.Dispose() }
                $expected = if ($mode -eq 'source') { 'Copy' } else { 'None' }
                if (-not [IO.File]::Exists($result) -or [IO.File]::ReadAllText($result) -ne $expected) { throw "Unexpected external $mode sidebar drag effect." }
                if ($mode -eq 'source') { Wait-Until { [IO.File]::Exists((Join-Path $sidebarSource 'external-source.txt')) } 'external file copy to sidebar' }
            } finally { Stop-ExternalProbe $process }
        }
        $start = Get-SidebarPoint $sidebarSource
        $probe = [DragMouseProbe]::new([int] $start.X, [int] $start.Y, [int] $start.X, [int] $start.Y, 0, $false, $true)
        try { Wait-Until { $probe.Done -and $navigation.Paths.Count -eq 1 } 'sidebar click navigation' }
        finally { $probe.Dispose() }
        if ($navigation.Paths[0] -ne $sidebarSource) { throw 'Sidebar click navigated to the wrong folder.' }
        $tree = $pathview.FindName('ActivePathAndSiblingsTree')
        $pathview.FindName('SidebarTabs').SelectedItem = $pathview.FindName('ActivePathAndSiblingsTab')
        $treeEntryType = $assembly.GetType('SUTWinExplorer.TreeEntry', $true)
        $treeRoot = [Activator]::CreateInstance($treeEntryType, [object[]] @('destination', [string] $destination))
        $treeChild = [Activator]::CreateInstance($treeEntryType, [object[]] @('target-folder', [string] $folderTarget))
        $treeRoot.IsLoaded = $true; $treeChild.IsLoaded = $true
        $treeRoot.Children.Add($treeChild)
        $treeRoot.HasSubdirectories = $true; $treeRoot.IsExpanded = $true
        $treeTop = $treeEntryType.GetMethod('Top').Invoke($null, @())
        $tree.ItemsSource = @($treeRoot, $treeTop)
        $rootContainer = $null; $childContainer = $null; $topContainer = $null
        Wait-Until {
            $script:rootContainer = $tree.ItemContainerGenerator.ContainerFromItem($treeRoot)
            $script:topContainer = $tree.ItemContainerGenerator.ContainerFromItem($treeTop)
            $script:childContainer = if ($null -ne $script:rootContainer) { $script:rootContainer.ItemContainerGenerator.ContainerFromItem($treeChild) } else { $null }
            $tree.IsVisible -and $null -ne $script:childContainer -and $null -ne $script:topContainer
        } 'large tree rows'
        $rootContainer = $script:rootContainer; $childContainer = $script:childContainer; $topContainer = $script:topContainer
        $treePoint = $childContainer.PointToScreen([System.Windows.Point]::new(60, 10))
        $treeFile = [string] (Join-Path $source 'tree-row.txt')
        [IO.File]::WriteAllText($treeFile, 'tree row')
        Invoke-MouseDrag @($treeFile) $treePoint 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'tree-row.txt')) } 'copy onto nested tree folder'
        if (-not [IO.File]::Exists($treeFile) -or [IO.File]::Exists((Join-Path $destination 'tree-row.txt'))) { throw 'Tree folder copy used the wrong destination or removed its source.' }
        Assert-BackgroundRejectsMoveAndLink 'tree-row' $treePoint $folderTarget
        $treeBackground = $tree.PointToScreen([System.Windows.Point]::new(60, $tree.ActualHeight - 20))
        $treeBackgroundFile = [string] (Join-Path $source 'tree-background.txt')
        [IO.File]::WriteAllText($treeBackgroundFile, 'tree background')
        Invoke-MouseDrag @($treeBackgroundFile) $treeBackground 0x11 $false
        Wait-Until { [IO.File]::Exists((Join-Path $destination 'tree-background.txt')) } 'copy onto tree background'
        if (-not [IO.File]::Exists($treeBackgroundFile)) { throw 'Tree background copy removed its source.' }
        Assert-BackgroundRejectsMoveAndLink 'tree-background' $treeBackground
        foreach ($case in @(@('copy', 0x11, 'Copy', '1:Copy', $treePoint), @('move', 0x10, 'None', '0:Cannot move here', $treePoint), @('link', 0xFF, 'None', '0:Cannot drop here', $treePoint), @('background-move', 0, 'None', '0:Cannot move here', $treeBackground))) {
            $name, $modifier, $expected, $expectedDescription, $end = $case
            $feedbackFile = [string] (Join-Path $source "tree-feedback-$name.txt")
            [IO.File]::WriteAllText($feedbackFile, $name)
            $result = Join-Path $root "tree-feedback-$name-result.txt"
            $external = Start-ExternalProbe 'source-all' $feedbackFile $result
            $process = $external[0]; $position = $external[1]
            try {
                $probe = [DragMouseProbe]::new($position[0], $position[1], [int] $end.X, [int] $end.Y, $modifier, $false)
                try { Wait-Until { $probe.Done -and [IO.File]::Exists($result) } "tree feedback $name" }
                finally { $probe.Dispose() }
                $feedback = [IO.File]::ReadAllText($result + '.feedback')
                $description = [IO.File]::ReadAllText($result + '.feedback.description')
                if ($feedback -ne $expected -or $description -ne $expectedDescription) { throw "Tree $name feedback=$feedback, description=$description." }
                if ($name -eq 'copy') { Wait-Until { [IO.File]::Exists((Join-Path $folderTarget 'tree-feedback-copy.txt')) } 'external tree copy' }
                elseif ([IO.File]::ReadAllText($result) -ne 'None' -or -not [IO.File]::Exists($feedbackFile) -or [IO.File]::Exists((Join-Path $folderTarget ([IO.Path]::GetFileName($feedbackFile)))) -or [IO.File]::Exists((Join-Path $destination ([IO.Path]::GetFileName($feedbackFile))))) { throw "Tree $name was not rejected." }
            } finally { Stop-ExternalProbe $process }
        }
        $topFile = [string] (Join-Path $source 'tree-top.txt')
        [IO.File]::WriteAllText($topFile, 'tree top')
        Invoke-MouseDrag @($topFile) ($topContainer.PointToScreen([System.Windows.Point]::new(60, 10))) 0x11 $false
        if (-not [IO.File]::Exists($topFile) -or [IO.File]::Exists((Join-Path $destination 'tree-top.txt'))) { throw 'The virtual tree item accepted a drop.' }
        if ($navigation.Paths.Count -ne 1) { throw 'Dropping on the large tree triggered navigation.' }
        }
    } finally {
        $window.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    $traceListener.Flush()
    if ($traceWriter.ToString() -match 'Drag image (update|drop|cleanup) failed') { throw "Shell drag-image manager failed: $traceWriter" }
    "Shell drag-and-drop $Suite tests passed."
} finally {
    [Diagnostics.Trace]::Listeners.Remove($traceListener)
    $traceListener.Dispose()
    [IO.Directory]::Delete($root, $true)
}