$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System.Runtime.InteropServices;
public static class PathTooltipProbe
{
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr window);
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
function Wait-Until([scriptblock] $condition, [string] $description) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $condition) -and $watch.ElapsedMilliseconds -lt 5000) { Pump 20 }
    if (-not (& $condition)) { throw "Timed out: $description." }
    return $watch.ElapsedMilliseconds
}
function Move-To([System.Windows.FrameworkElement] $element, [double] $x, [double] $y) {
    $point = $element.PointToScreen([System.Windows.Point]::new($x, $y))
    $null = [PathTooltipProbe]::SetCursorPos([int] $point.X, [int] $point.Y)
}
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$directory = Join-Path ([IO.Path]::GetTempPath()) ('kis-tooltip-' + [guid]::NewGuid().ToString('N'))
$cursor = [PathTooltipProbe+Point]::new()
$null = [PathTooltipProbe]::GetCursorPos([ref] $cursor)
$window = $null
try {
    [void] [IO.Directory]::CreateDirectory($directory)
    $constructor = $assembly.GetType('SUTWinExplorer.Pathview', $true).GetConstructors()[0]
    $view = $constructor.Invoke([object[]] @([string] $directory, $true, $null, $null, $null, $null))
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Left = [System.Windows.SystemParameters]::WorkArea.Left + 40
    $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 40
    $window.Width = 900
    $window.Height = 600
    $window.Content = $view
    $window.Show()
    $null = $window.Activate()
    $window.UpdateLayout()
    $label = $view.FindName('LocationLabel')
    $icon = $view.FindName('LocationIconSlot')
    $display = $view.FindName('LocationDisplay')
    if ([System.Windows.Controls.ToolTipService]::GetInitialShowDelay($display) -ne 200 -or
        [System.Windows.Controls.ToolTipService]::GetPlacement($display) -ne [System.Windows.Controls.Primitives.PlacementMode]::Bottom -or
        [System.Windows.Controls.ToolTipService]::GetPlacementTarget($display) -ne $label) {
        throw 'Incorrect path tooltip delay or placement.'
    }
    $events = @{ Opened = 0 }
    $display.add_ToolTipOpening({ $events.Opened++ }.GetNewClosure())
    $nestedDirectory = Join-Path $directory ('long-path-' + ('W' * 100))
    [void] [IO.Directory]::CreateDirectory($nestedDirectory)
    foreach ($path in @($directory, $nestedDirectory)) {
        $null = [PathTooltipProbe]::SetCursorPos([int] ($window.Left - 10), [int] $window.Top)
        Pump 1000
        $view.Navigate($path, $null, $null, $null)
        $window.UpdateLayout()
        $openedBefore = $events.Opened
        if ($path -eq $directory) { Move-To $label 10 ($label.ActualHeight / 2) }
        else { Move-To $icon 12 12 }
        $openDelay = Wait-Until { $events.Opened -gt $openedBefore } 'path tooltip opens'
        $tooltip = [System.Windows.Controls.ToolTip] $display.ToolTip
        $null = Wait-Until { $tooltip.IsOpen } 'path tooltip is visible'
        $tooltipText = [System.Windows.Controls.TextBlock] $tooltip.Content
        if ($tooltipText.Text -cne $label.Text -or $tooltipText.TextWrapping -ne [System.Windows.TextWrapping]::Wrap -or
            $label.Text -cnotmatch [regex]::Escape([IO.Path]::GetFileName($path))) {
            throw 'The path tooltip does not contain the current full display path.'
        }
        $position = $tooltip.PointToScreen([System.Windows.Point]::new(0, 0))
        $labelBottom = $label.PointToScreen([System.Windows.Point]::new(0, $label.ActualHeight))
        $rightEdge = $window.PointToScreen([System.Windows.Point]::new($window.ActualWidth, 0)).X
        $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($tooltip).DpiScaleX
        if ([Math]::Abs($position.Y - $labelBottom.Y) -gt 3 -or [Math]::Abs($position.X - $labelBottom.X) -gt 3) { throw "The path tooltip is not aligned below the label: tooltip=$position, label bottom=$labelBottom." }
        if ($position.X + $tooltip.ActualWidth * $scale -gt $rightEdge + 3 -or
            ($path -eq $nestedDirectory -and $tooltipText.ActualHeight -le $tooltipText.FontSize * 2)) {
            throw "The path tooltip does not wrap inside the window: position=$position, width=$($tooltip.ActualWidth), right edge=$rightEdge."
        }
        if ($path -eq $nestedDirectory) {
            $previousMaxWidth = $tooltip.MaxWidth
            $window.Width -= 150
            $null = Wait-Until { $tooltip.IsOpen -and $tooltip.MaxWidth -lt $previousMaxWidth - 100 } 'open path tooltip responds to resizing'
            $position = $tooltip.PointToScreen([System.Windows.Point]::new(0, 0))
            $rightEdge = $window.PointToScreen([System.Windows.Point]::new($window.ActualWidth, 0)).X
            if ($position.X + $tooltip.ActualWidth * $scale -gt $rightEdge + 3) { throw 'The resized path tooltip extends beyond the window.' }
        }
        if ($path -eq $directory) { Move-To $icon 12 12 }
        else { Move-To $label 10 ($label.ActualHeight / 2) }
        for ($sample = 0; $sample -lt 6; $sample++) {
            Pump 50
            if (-not $tooltip.IsOpen -or $events.Opened -ne $openedBefore + 1) {
                throw 'The path tooltip closed or reopened while moving between the icon and the label.'
            }
        }
        Pump 150
        $popupHandle = ([System.Windows.Interop.HwndSource] [System.Windows.PresentationSource]::FromVisual($tooltip)).Handle
        $popupRect = [PathTooltipProbe+Rect]::new()
        if (-not [PathTooltipProbe]::GetWindowRect($popupHandle, [ref] $popupRect)) { throw 'The tooltip popup window was not found.' }
        $popupWidth = $popupRect.Right - $popupRect.Left
        $null = [PathTooltipProbe]::SetCursorPos([int] ($window.Left - 10), [int] $window.Top)
        $closeDelay = Wait-Until { -not $tooltip.IsOpen } 'path tooltip closes'
        if ($tooltipText.Text -cne $label.Text) { throw 'The path tooltip text disappeared during closing.' }
        $closingWatch = [Diagnostics.Stopwatch]::StartNew()
        while ($closingWatch.ElapsedMilliseconds -lt 250) {
            if ([PathTooltipProbe]::IsWindowVisible($popupHandle) -and
                [PathTooltipProbe]::GetWindowRect($popupHandle, [ref] $popupRect) -and
                $popupRect.Right - $popupRect.Left -lt $popupWidth - 4) {
                throw 'The tooltip popup shrank while still visible.'
            }
            Pump 10
        }
        if ($tooltipText.Text -cne $label.Text) { throw 'The path tooltip text disappeared after closing.' }
        "Path tooltip: opened after ${openDelay}ms, closed after ${closeDelay}ms."
    }
    $window.Close()
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $storeType = $assembly.GetType('SUTWinExplorer.UseCaseStore', $true)
    $store = [Activator]::CreateInstance($storeType, [object[]] @([string] (Join-Path $directory 'use-cases'), [string] 'test'))
    $useCase = $storeType.GetMethod('LoadOrCreate').Invoke($store, @())
    $application.GetType().GetMethod('SetActiveUseCase', $flags).Invoke($application, [object[]] @($store, $useCase))
    $window = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.MainWindow', $true))
    $rendered = $window.GetType().GetMethod('MainWindow_ContentRendered', $flags)
    $window.remove_ContentRendered([EventHandler]::CreateDelegate([EventHandler], $window, $rendered))
    $add = $window.GetType().GetMethod('AddPaneview', $flags)
    $add.Invoke($window, [object[]] @([string] $directory, $true, $null, $true))
    $add.Invoke($window, [object[]] @([string] $nestedDirectory, $false, $null, $false))
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Left = [System.Windows.SystemParameters]::WorkArea.Left + 40
    $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 40
    $window.Width = 1000
    $window.Height = 600
    $window.Show()
    $null = $window.Activate()
    $window.UpdateLayout()
    $tabs = $window.FindName('ExplorerTabs')
    $firstHeader = $tabs.Items[0].Header
    $secondHeader = $tabs.Items[1].Header
    foreach ($header in @($firstHeader, $secondHeader)) {
        if ([System.Windows.Controls.ToolTipService]::GetInitialShowDelay($header) -ne 200 -or
            [System.Windows.Controls.ToolTipService]::GetBetweenShowDelay($header) -ne 100) {
            throw 'The tab tooltip delays are incorrect.'
        }
    }
    $null = [PathTooltipProbe]::SetCursorPos([int] ($window.Left - 10), [int] $window.Top)
    Pump 1000
    Move-To $firstHeader 5 ($firstHeader.ActualHeight / 2)
    $firstDelay = Wait-Until { $firstHeader.ToolTip.IsOpen } 'first tab tooltip opens'
    Move-To $secondHeader 5 ($secondHeader.ActualHeight / 2)
    $switchDelay = Wait-Until { $secondHeader.ToolTip.IsOpen } 'next tab tooltip opens'
    if ($firstDelay -ge 1000 -or $switchDelay -ge 1000) { throw "Tab tooltip delays were too long: first=$firstDelay, switch=$switchDelay." }
    "Tab tooltips: first opened after ${firstDelay}ms, next after ${switchDelay}ms."
} finally {
    $null = [PathTooltipProbe]::SetCursorPos($cursor.X, $cursor.Y)
    if ($null -ne $window) { $window.Close() }
    $application.Shutdown()
    if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory, $true) }
}