$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public static class ColumnToggleMouseProbe
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct Point { public int X; public int Y; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    public static void Click() { mouse_event(2, 0, 0, 0, System.UIntPtr.Zero); mouse_event(4, 0, 0, 0, System.UIntPtr.Zero); }
    public static void Down() => mouse_event(2, 0, 0, 0, System.UIntPtr.Zero);
    public static void Up() => mouse_event(4, 0, 0, 0, System.UIntPtr.Zero);
}
public sealed class ColumnResizeProbe : System.IDisposable
{
    private readonly int startX, startY;
    private readonly System.Threading.Timer timer;
    private int phase;
    public volatile bool Finished;
    public ColumnResizeProbe(int x, int y)
    {
        startX = x; startY = y;
        timer = new System.Threading.Timer(Tick, null, 100, 150);
    }
    private void Tick(object state)
    {
        switch (System.Threading.Interlocked.Increment(ref phase))
        {
            case 1: ColumnToggleMouseProbe.SetCursorPos(startX, startY); break;
            case 2: ColumnToggleMouseProbe.Down(); break;
            case 3: ColumnToggleMouseProbe.SetCursorPos(startX + 15, startY); break;
            case 4: ColumnToggleMouseProbe.SetCursorPos(startX + 30, startY); break;
            case 5: ColumnToggleMouseProbe.Up(); Finished = true; timer.Change(-1, -1); break;
        }
    }
    public void Dispose() => timer.Dispose();
}
'@

function Find-VisualChild($parent, [type] $type) {
    for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
        if ($type.IsInstanceOfType($child)) { return $child }
        $found = Find-VisualChild $child $type
        if ($null -ne $found) { return $found }
    }
    return $null
}

function Update-Layout($window) {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $window.UpdateLayout()
}

function Assert-State($view, $window, [bool] $hidden) {
    Update-Layout $window
    $columns = $view.FindName('FileList').View.Columns
    $header = $view.FindName('RightColumnsToggleHeader')
    $symbol = $view.FindName('RightColumnsToggleSymbol')
    $expectedSymbol = if ($hidden) { [char] 0x2026 } else { [char] 0x25B8 }
    $scroll = Find-VisualChild $view.FindName('FileList') ([System.Windows.Controls.ScrollViewer])
    $width = ($columns | ForEach-Object Width | Measure-Object -Sum).Sum
    $nameIndex = $columns.IndexOf($view.FindName('NameColumn'))
    $typeApp1Index = $columns.IndexOf($view.FindName('TypeApp1Icon'))
    $toggleIndex = $columns.IndexOf($view.FindName('RightColumnsToggleColumn'))
    if ($columns.Count -ne $(if ($hidden) { 6 } else { 9 }) -or
        $nameIndex -lt 0 -or $typeApp1Index -ne $nameIndex + 1 -or $toggleIndex -ne $typeApp1Index + 1 -or
        -not [object]::ReferenceEquals($view.FindName('RightColumnsToggleColumn').Header, $header) -or
        $symbol.Text -cne [string] $expectedSymbol -or [string]::IsNullOrWhiteSpace([string] $header.ToolTip) -or
        [System.Windows.Automation.AutomationProperties]::GetName($header) -cne $header.ToolTip -or
        $header.Padding.Left -ne 0 -or $header.Padding.Right -ne 0 -or
        $symbol.ActualWidth -lt $symbol.DesiredSize.Width -or $symbol.ActualWidth -gt $header.ActualWidth -or
        [Math]::Abs($width - $scroll.ViewportWidth) -gt 1 -or $scroll.ScrollableWidth -gt 1) {
        throw "Incorrect columns or toggle: hidden=$hidden, count=$($columns.Count), symbol=$($symbol.Text), symbol width=$($symbol.ActualWidth)/$($symbol.DesiredSize.Width), header=$($header.ActualWidth), columns=$width, viewport=$($scroll.ViewportWidth)."
    }
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
$window = [System.Windows.Window]::new()
$window.ShowInTaskbar = $false
$window.Left = -20000
$window.Top = -20000
$window.Width = 1000
$window.Height = 300
$window.Content = $view
try {
    $window.Show()
    Assert-State $view $window $false
    $list = $view.FindName('FileList')
    $header = $view.FindName('RightColumnsToggleHeader')
    $rowType = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true)
    $rows = [Array]::CreateInstance($rowType, 2)
    $rows.SetValue([Activator]::CreateInstance($rowType, $true), 0)
    $rows.SetValue([Activator]::CreateInstance($rowType, $true), 1)
    $list.ItemsSource = $rows
    $list.SelectedItem = $rows[0]
    $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $sorting = $view.GetType().GetField('_sorting', $flags).GetValue($view)
    $pairs = $sorting.GetType().GetProperty('Pairs', $flags)
    $beforeSort = @($pairs.GetValue($sorting)) -join ';'
    $header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-State $view $window $true
    if ((@($pairs.GetValue($sorting)) -join ';') -cne $beforeSort -or
        -not [object]::ReferenceEquals($list.ItemsSource, $rows) -or
        -not [object]::ReferenceEquals($list.SelectedItem, $rows[0])) { throw 'Toggling changed sorting, rows, or selection.' }
    $window.Width = 1100
    Assert-State $view $window $true
    $header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-State $view $window $false
    $columns = $list.View.Columns
    $toggleIndex = $columns.IndexOf($view.FindName('RightColumnsToggleColumn'))
    if ($columns.IndexOf($view.FindName('TypeApp2Name')) -ne $toggleIndex + 1 -or
        $columns.IndexOf($view.FindName('SizeColumn')) -ne $toggleIndex + 2 -or
        $columns.IndexOf($view.FindName('DateColumn')) -ne $toggleIndex + 3) { throw 'Restored columns are out of order.' }
    $window.Width = 500
    Assert-State $view $window $true
    $header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-State $view $window $false
    $window.Width = 490
    Assert-State $view $window $true
    $window.Width = 1100
    Assert-State $view $window $false
    $cursor = [ColumnToggleMouseProbe+Point]::new()
    $null = [ColumnToggleMouseProbe]::GetCursorPos([ref] $cursor)
    try {
        $window.Left = [System.Windows.SystemParameters]::WorkArea.Left + 20
        $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 20
        $null = $window.Activate()
        Update-Layout $window
        $nameColumn = $view.FindName('NameColumn')
        $typeColumn = $view.FindName('TypeApp2Name')
        $nameHeader = $nameColumn.Header
        $gripper = $nameHeader.Template.FindName('PART_HeaderGripper', $nameHeader)
        $gripPoint = $gripper.PointToScreen([System.Windows.Point]::new($gripper.ActualWidth / 2, $gripper.ActualHeight / 2))
        $oldNameWidth = $nameColumn.Width
        $oldTypeWidth = $typeColumn.Width
        $drag = [ColumnResizeProbe]::new([int] $gripPoint.X, [int] $gripPoint.Y)
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $timer.add_Tick({ if ($drag.Finished -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop(); $drag.Dispose() }
        if (-not $drag.Finished -or $nameColumn.Width -le $oldNameWidth + 10 -or
            $typeColumn.Width -ge $oldTypeWidth - 10) { throw 'The Name column resize grip did not resize Name and TA2.' }
        $typeHeader = $view.FindName('TypeApp1Icon').Header
        $typeGripper = $typeHeader.Template.FindName('PART_HeaderGripper', $typeHeader)
        if ($typeGripper.IsHitTestVisible) { throw 'The TA1 resize grip must not intercept clicks.' }
        $hidden = $false
        foreach ($offset in @(2, ($header.ActualWidth / 2), ($header.ActualWidth - 2))) {
            $point = $header.PointToScreen([System.Windows.Point]::new($offset, $header.ActualHeight / 2))
            $null = [ColumnToggleMouseProbe]::SetCursorPos([int] $point.X, [int] $point.Y)
            Update-Layout $window
            $hit = $window.InputHitTest($window.PointFromScreen($point))
            while ($null -ne $hit -and -not [object]::ReferenceEquals($hit, $header)) {
                $hit = [System.Windows.Media.VisualTreeHelper]::GetParent($hit)
            }
            if ($null -eq $hit) { throw "The toggle header is covered at $point." }
            [ColumnToggleMouseProbe]::Click()
            $hidden = -not $hidden
            Assert-State $view $window $hidden
        }
    } finally {
        [ColumnToggleMouseProbe]::Up()
        $null = [ColumnToggleMouseProbe]::SetCursorPos($cursor.X, $cursor.Y)
    }
    Write-Output 'ContentView column toggle tests passed.'
} finally {
    $window.Close()
    $application.Shutdown()
}