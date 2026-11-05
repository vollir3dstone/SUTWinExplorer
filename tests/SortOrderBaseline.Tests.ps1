$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

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
        $pairs[5].Criterion -ne 'Descending') { throw 'ContentView did not map widget indices and directions.' }
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