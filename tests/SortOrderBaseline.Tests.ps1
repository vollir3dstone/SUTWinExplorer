$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public sealed class SortOrderDragProbe : System.IDisposable
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    private readonly int startX, startY, targetX, targetY;
    private readonly System.Threading.Timer timer;
    private int phase;
    public volatile bool Finished;
    public SortOrderDragProbe(int startX, int startY, int targetX, int targetY)
    {
        this.startX = startX; this.startY = startY; this.targetX = targetX; this.targetY = targetY;
        timer = new System.Threading.Timer(Tick, null, 100, 150);
    }
    private void Tick(object state)
    {
        switch (System.Threading.Interlocked.Increment(ref phase))
        {
            case 1: SetCursorPos(startX, startY); break;
            case 2: mouse_event(2, 0, 0, 0, System.UIntPtr.Zero); break;
            case 3: SetCursorPos(startX + 12, startY); break;
            case 4: SetCursorPos(targetX, targetY); break;
            case 5: ReleaseButton(); Finished = true; timer.Change(-1, -1); break;
        }
    }
    public static int[] CursorPosition() { GetCursorPos(out var point); return new[] { point.X, point.Y }; }
    public static void MovePointer(int x, int y) => SetCursorPos(x, y);
    public static void ReleaseButton() => mouse_event(4, 0, 0, 0, System.UIntPtr.Zero);
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

function Assert-Baselines($view) {
    $editor = $view.FindName('SortOrderEditor')
    $boxes = $editor.Child
    $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($editor)
    while ($null -ne $parent -and $parent -isnot [System.Windows.Controls.TextBlock]) {
        $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($parent)
    }
    if ($null -eq $parent) { throw 'The sort editor is not in the VIEW text line.' }
    $lineBaseline = $parent.TranslatePoint([System.Windows.Point]::new(0, $parent.BaselineOffset), $view).Y
    $resetLabel = $view.FindName('ResetViewLabel')
    $resetBaseline = $resetLabel.TranslatePoint([System.Windows.Point]::new(0, $resetLabel.BaselineOffset), $view).Y
    if ([Math]::Abs($resetBaseline - $lineBaseline) -gt 0.5) {
        throw "Reset text baseline $resetBaseline differs from the surrounding text baseline $lineBaseline."
    }
    foreach ($name in @('HideDirectoriesCheckBox', 'HideInternalContentCheckBox')) {
        $checkbox = $view.FindName($name)
        $baseline = $checkbox.TranslatePoint([System.Windows.Point]::new(0, $checkbox.BaselineOffset), $view).Y
        if ([Math]::Abs($baseline - $lineBaseline) -gt 0.5) {
            throw "$name baseline $baseline differs from the surrounding text baseline $lineBaseline."
        }
    }
    $headerContent = $view.FindName('NameColumn').Header.Content
    $headerLabel = $headerContent.Children[0]
    $headerArrow = $headerContent.Children[1]
    $headerOffset = $headerArrow.TranslatePoint([System.Windows.Point]::new(0, $headerArrow.BaselineOffset), $view).Y -
        $headerLabel.TranslatePoint([System.Windows.Point]::new(0, $headerLabel.BaselineOffset), $view).Y
    foreach ($button in $boxes.Children) {
        $texts = @($button.Content.Children)
        if ($texts.Count -ne 2 -or $texts[0].Text -notmatch '^\S+$' -or
            $texts[1].Text -notmatch '^[\u25B2\u25BC]$' -or $texts[1].FontSize -ne $headerArrow.FontSize -or
            $texts[1].FontSize -ge $texts[0].FontSize -or $texts[1].Margin.Left -ne 0) {
            throw 'Sort box arrow does not match the table arrow size or has a gap.'
        }
        $outline = $button.Template.FindName('outline', $button)
        if ($null -eq $outline -or $outline.BorderThickness -ne [System.Windows.Thickness]::new(1, 0, 0, 0) -or
            $outline.CornerRadius -ne [System.Windows.CornerRadius]::new(0)) { throw 'A sort box has a border other than its straight left line.' }
        $text = Find-VisualChild $button ([System.Windows.Controls.TextBlock])
        if ($null -eq $text) { throw 'A sort box has no rendered text.' }
        $arrowOffset = $texts[1].TranslatePoint([System.Windows.Point]::new(0, $texts[1].BaselineOffset), $view).Y -
            $texts[0].TranslatePoint([System.Windows.Point]::new(0, $texts[0].BaselineOffset), $view).Y
        if ([Math]::Abs($arrowOffset - $headerOffset) -gt 0.5) {
            throw "Sort arrow vertical offset $arrowOffset differs from table header offset $headerOffset."
        }
        $baseline = $text.TranslatePoint([System.Windows.Point]::new(0, $text.BaselineOffset), $view).Y
        if ([Math]::Abs($baseline - $lineBaseline) -gt 0.5) {
            throw "Sort box baseline $baseline differs from the surrounding text baseline $lineBaseline."
        }
        if ($button.ActualHeight -gt $editor.ActualHeight - 2) { throw 'A sort box exceeds the editor interior.' }
    }
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$widget = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.SortOrderWidget', $true))
$widget.Foreground = [System.Windows.Media.Brushes]::DarkGreen
$widget.Background = [System.Windows.Media.Brushes]::Ivory
$changed = [pscustomobject] @{ Count = 0 }
$widget.add_Changed({ $changed.Count++ }.GetNewClosure())
$names = [string[]] @('alpha beta', 'same', 'same', 'other')
$widget.Configure($names)
$names[0] = 'changed outside'
if ((@($widget.Items).Index -join ',') -cne '0,1,2,3' -or
    @($widget.Items | Where-Object { $_.Direction -ne 'Ascending' }).Count -ne 0 -or
    $widget.Child.Children[0].Content.Children[0].Text -cne 'alpha beta' -or
    $widget.Child.Children[0].Content.Children[1].Text -cne [string] [char] 0x25B2) { throw 'Configuring arbitrary names did not create stable ascending indices.' }
foreach ($button in $widget.Child.Children) {
    if ($button.Foreground -ne $widget.Foreground -or $button.Background -ne $widget.Background) { throw 'Sort box colors did not use the widget colors.' }
}
$widget.Foreground = [System.Windows.Media.Brushes]::DarkBlue
$widget.Background = [System.Windows.Media.Brushes]::LightYellow
foreach ($button in $widget.Child.Children) {
    if ($button.Foreground -ne $widget.Foreground -or $button.Background -ne $widget.Background) { throw 'Changing widget colors did not update existing boxes.' }
}
$initialSnapshot = $widget.Items
$widget.Child.Children[2].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
if (@($widget.Items)[2].Direction -ne 'Descending' -or @($initialSnapshot)[2].Direction -ne 'Ascending') { throw 'Box clicks or immutable snapshots failed.' }
$widget.Select(2)
if ((@($widget.Items).Index -join ',') -cne '2,0,1,3' -or @($widget.Items)[0].Direction -ne 'Descending') { throw 'Selecting an index failed to preserve its direction.' }
$widget.Select(2)
if (@($widget.Items)[0].Direction -ne 'Ascending') { throw 'Selecting the primary index did not reverse its direction.' }
$genericMove = $widget.GetType().GetMethod('MoveItem', [System.Reflection.BindingFlags]'Instance,NonPublic')
$null = $genericMove.Invoke($widget, [object[]] @([int] 2, [int] 4))
if ((@($widget.Items).Index -join ',') -cne '0,1,3,2' -or $changed.Count -ne 5) { throw 'Moving an index or change notifications failed.' }
foreach ($button in $widget.Child.Children) {
    if ($button.Foreground -ne $widget.Foreground -or $button.Background -ne $widget.Background -or
        $button.BorderThickness -ne [System.Windows.Thickness]::new(1, 0, 0, 0)) { throw 'Recreated boxes lost their configured colors or left border.' }
}
$widget.Child.Children[0].BorderThickness = [System.Windows.Thickness]::new(1, 0, 3, 0)
$clearMarker = $widget.GetType().GetMethod('ClearDropMarker', [System.Reflection.BindingFlags]'Instance,NonPublic')
$null = $clearMarker.Invoke($widget, @())
if ($widget.Child.Children[0].BorderThickness -ne [System.Windows.Thickness]::new(1, 0, 0, 0)) { throw 'Clearing a drag marker did not restore the left border.' }
$widget.Configure([string[]] @())
if (@($widget.Items).Count -ne 0) { throw 'An empty widget must have no sort pairs.' }
$invalid = $false
try { $widget.Select(0) } catch { $invalid = $true }
if (-not $invalid) { throw 'An invalid index was accepted.' }
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
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $window.UpdateLayout()
    $viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $viewSort = $view.GetType().GetField('_sorting', $viewFlags).GetValue($view)
    $pairsProperty = $viewSort.GetType().GetProperty('Pairs', $viewFlags)
    $sortWidget = $view.FindName('SortOrderEditor')
    $sortBoxes = $sortWidget.Child
    $defaultOrder = 'Name,MediaTypeIcon,TypeApp1Icon,TypeApp2Name,DateModified,Size'
    if ((@($pairsProperty.GetValue($viewSort)).Column -join ',') -cne $defaultOrder -or
        @($pairsProperty.GetValue($viewSort) | Where-Object { $_.Criterion -ne 'Ascending' }).Count -ne 0 -or
        ($sortBoxes.Children | ForEach-Object { $_.Tag }) -join ',' -cne '0,1,2,3,4,5' -or
        $view.FindName('NameSortIndicator').Visibility -ne 'Visible') { throw 'The initial sort widget or its criteria are incorrect.' }
    $sortBoxes.Children[1].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    if (@($pairsProperty.GetValue($viewSort))[1].Criterion -ne 'Descending' -or
        $sortBoxes.Children[1].Content.Children[1].Text -cne [string] [char] 0x25BC) { throw 'Clicking a sort box did not reverse its direction.' }
    $view.FindName('MediaTypeIcon').Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    if (@($pairsProperty.GetValue($viewSort))[0].Column -ne 'MediaTypeIcon' -or
        @($pairsProperty.GetValue($viewSort))[0].Criterion -ne 'Descending' -or
        $sortBoxes.Children[0].Tag -ne 1 -or $view.FindName('MediaTypeIconSortIndicator').Text -cne [string] [char] 0x25BC) { throw 'A header click did not preserve the box direction and promote it.' }
    $moveSortColumn = $sortWidget.GetType().GetMethod('MoveItem', $viewFlags)
    $null = $moveSortColumn.Invoke($sortWidget, [object[]] @([int] 1, [int] 6))
    if (@($pairsProperty.GetValue($viewSort))[5].Column -ne 'MediaTypeIcon' -or
        @($pairsProperty.GetValue($viewSort))[5].Criterion -ne 'Descending' -or $sortBoxes.Children[5].Tag -ne 1) { throw 'Moving a sort box did not preserve its criterion.' }
    $sortWidget.Configure([string[]] @('Name', 'MT', 'TA1', 'TA2', 'Date', 'Size'))
    $originalCursor = [SortOrderDragProbe]::CursorPosition()
    try {
        $window.Left = 20
        $window.Top = 20
        $window.Width = [Math]::Min(1200, [System.Windows.SystemParameters]::WorkArea.Width - 40)
        $null = $window.Activate()
        $sortWidget.BringIntoView()
        $null = $sortBoxes.Children[0].Focus()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $window.UpdateLayout()
        $start = $sortBoxes.Children[0].PointToScreen([System.Windows.Point]::new($sortBoxes.Children[0].ActualWidth / 2, $sortBoxes.Children[0].ActualHeight / 2))
        $target = $sortBoxes.Children[2].PointToScreen([System.Windows.Point]::new($sortBoxes.Children[2].ActualWidth - 4, $sortBoxes.Children[2].ActualHeight / 2))
        $drag = [SortOrderDragProbe]::new([int] $start.X, [int] $start.Y, [int] $target.X, [int] $target.Y)
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        $timer.add_Tick({ if ($drag.Finished -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop(); $drag.Dispose() }
        if (-not $drag.Finished -or (@($pairsProperty.GetValue($viewSort)).Column -join ',') -cne 'MediaTypeIcon,TypeApp1Icon,Name,TypeApp2Name,DateModified,Size' -or
            @($pairsProperty.GetValue($viewSort) | Where-Object { $_.Criterion -ne 'Ascending' }).Count -ne 0) {
            throw "Dragging a sort box did not preserve directions and reorder the criteria: start=$start, target=$target, pairs=$(@($pairsProperty.GetValue($viewSort)) -join '; ')."
        }
    } finally {
        [SortOrderDragProbe]::ReleaseButton()
        [SortOrderDragProbe]::MovePointer($originalCursor[0], $originalCursor[1])
        $window.Left = -20000
        $window.Top = -20000
        $window.Width = 1000
        $sortWidget.Configure([string[]] @('Name', 'MT', 'TA1', 'TA2', 'Date', 'Size'))
        $view.FindName('ViewControlsScroll').ScrollToLeftEnd()
    }
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $window.Content = $view
    $window.UpdateLayout()
    Assert-Baselines $view
    $editor = $view.FindName('SortOrderEditor')
    $boxes = $editor.Child
    foreach ($button in $boxes.Children) {
        if ($button.Foreground -ne [System.Windows.SystemColors]::WindowTextBrush -or
            $button.Background -ne [System.Windows.SystemColors]::WindowBrush) { throw 'ContentView did not use normal text and editor colors.' }
    }
    $boxes.Children[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $move = $editor.GetType().GetMethod('MoveItem', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $null = $move.Invoke($editor, [object[]] @([int] 0, [int] 6))
    $viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $sortState = $view.GetType().GetField('_sorting', $viewFlags).GetValue($view)
    $pairs = @($sortState.GetType().GetProperty('Pairs', $viewFlags).GetValue($sortState))
    if (($pairs.Column -join ',') -cne 'MediaTypeIcon,TypeApp1Icon,TypeApp2Name,DateModified,Size,Name' -or
        $pairs[5].Criterion -ne 'Descending') { throw "ContentView did not map widget indices and directions: $($pairs -join '; ')." }
    $view.FindName('NameColumn').Header.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $pairs = @($sortState.GetType().GetProperty('Pairs', $viewFlags).GetValue($sortState))
    if ($pairs[0].Column -ne 'Name' -or $pairs[0].Criterion -ne 'Descending' -or
        @($editor.Items)[0].Index -ne 0 -or @($editor.Items)[0].Direction -ne 'Descending') { throw 'A table header did not synchronize the widget and sorting.' }
    $window.Width = 500
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $window.UpdateLayout()
    Assert-Baselines $view
    Write-Output 'Sort order widget and baseline tests passed.'
} finally {
    $window.Close()
    $application.Shutdown()
}