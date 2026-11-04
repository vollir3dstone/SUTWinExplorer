$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System.Runtime.InteropServices;
public static class TooltipMouseProbe
{
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
'@
function Wait-Until([scriptblock] $condition, [string] $description) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(25)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $state = @{ Ready = $false }
    $timer.add_Tick({
        if (& $condition) { $state.Ready = $true; $frame.Continue = $false }
        elseif ([DateTime]::UtcNow -gt $deadline) { $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
    if (-not $state.Ready) { throw "Timed out: $description." }
}
function Find-NameElement([System.Windows.DependencyObject] $parent) {
    for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
        if ($child -is [System.Windows.Controls.TextBlock] -and $child.Name -eq 'ItemName') { return $child }
        $found = Find-NameElement $child
        if ($null -ne $found) { return $found }
    }
}
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '../bin/Debug/net10.0-windows/SUTWinExplorer.dll'))
[System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
$window = [System.Windows.Window]::new()
$window.ShowInTaskbar = $false
$window.Topmost = $true
$window.Left = [System.Windows.SystemParameters]::WorkArea.Left + 20
$window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 20
$window.Width = [Math]::Min(1400, [System.Windows.SystemParameters]::WorkArea.Width - 40)
$window.Height = 400
$window.Content = $view
$cursor = [TooltipMouseProbe+Point]::new()
$null = [TooltipMouseProbe]::GetCursorPos([ref] $cursor)
try {
    $window.Show(); $null = $window.Activate()
    $list = $view.FindName('FileList')
    $rowType = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true)
    $constructor = $rowType.GetConstructor([Reflection.BindingFlags]'Instance,NonPublic', $null, [type[]] @([string]), $null)
    $path = 'C:\' + ('W' * 180)
    $row = $constructor.Invoke([object[]] @($path))
    $items = [Array]::CreateInstance($rowType, 1)
    $items.SetValue($row, 0)
    $list.ItemsSource = $items
    $widths = @($window.Width, ($window.Width - 350))
    foreach ($width in $widths) {
        if ($width -ne $widths[0]) {
            $displayName = 'Display-' + ('W' * 180)
            $entryType = $assembly.GetType('SUTWinExplorer.FileEntry', $true)
            $entry = [Activator]::CreateInstance($entryType, [object[]] @($displayName, $path, $false, '', '', $null, $null, $null, ''))
            $row.Entry = $entry
        } else { $displayName = [IO.Path]::GetFileName($path) }
        $window.Width = $width
        $window.UpdateLayout()
        $container = $list.ItemContainerGenerator.ContainerFromItem($row)
        $root = [System.Windows.Media.VisualTreeHelper]::GetChild($container, 0)
        $tooltip = [System.Windows.Controls.ToolTip] $root.ToolTip
        if ($null -eq $tooltip -or [System.Windows.Controls.ToolTipService]::GetInitialShowDelay($root) -ne 500) { throw 'The row tooltip or its delay is missing.' }
        $outside = $window.PointToScreen([System.Windows.Point]::new(5, 5))
        $null = [TooltipMouseProbe]::SetCursorPos([int] $outside.X, [int] $outside.Y)
        Wait-Until { -not $root.IsMouseOver } 'pointer leaves row'
        $point = $container.PointToScreen([System.Windows.Point]::new(30, 10))
        $null = [TooltipMouseProbe]::SetCursorPos([int] $point.X, [int] $point.Y)
        try { Wait-Until { $tooltip.IsOpen } "row tooltip opens at width $width" }
        catch { throw "$_ MouseOver=$($root.IsMouseOver), active=$($window.IsActive), target=$($tooltip.PlacementTarget), point=$point." }
        $tooltipText = [System.Windows.Controls.TextBlock] $tooltip.Content
        $popup = $tooltip.PointToScreen([System.Windows.Point]::new(0, 0))
        $nameElement = Find-NameElement $root
        if ($null -eq $nameElement) { throw 'Name cell was not found.' }
        $nameStart = $nameElement.PointToScreen([System.Windows.Point]::new(0, 0))
        $rowEnd = $container.PointToScreen([System.Windows.Point]::new($container.ActualWidth, 0))
        $rowBottom = $container.PointToScreen([System.Windows.Point]::new(0, $container.ActualHeight)).Y
        if ($tooltipText.Text -cne $displayName -or $tooltipText.TextWrapping -ne [System.Windows.TextWrapping]::Wrap -or
            $tooltipText.ActualHeight -le $tooltipText.FontSize * 2 -or
            $tooltip.ActualWidth -gt $tooltip.MaxWidth + 1 -or $tooltip.ActualWidth -lt $tooltip.MaxWidth - 30 -or
            $popup.Y -lt $rowBottom -or [Math]::Abs($popup.X - $nameStart.X) -gt 10 -or $popup.X + $tooltip.ActualWidth -gt $rowEnd.X + 3) {
            throw "Incorrect tooltip at window width $width`: name=$($tooltipText.Text), width=$($tooltip.ActualWidth), max=$($tooltip.MaxWidth), position=$popup, name position=$nameStart."
        }
        if ($width -eq $widths[0]) {
            $previousMaxWidth = $tooltip.MaxWidth
            $window.Width = $widths[1]
            Wait-Until { $tooltip.IsOpen -and $tooltip.MaxWidth -lt $previousMaxWidth - 100 } 'open tooltip responds to resizing'
        }
        $null = [TooltipMouseProbe]::SetCursorPos([int] $window.Left, [int] $window.Top)
        Wait-Until { -not $tooltip.IsOpen } 'row tooltip closes'
    }
    'ContentView tooltip tests passed.'
} finally {
    $null = [TooltipMouseProbe]::SetCursorPos($cursor.X, $cursor.Y)
    $window.Close()
    $application.Shutdown()
}