param([string] $Title, [string] $Path, [string] $Mode, [string] $ResultPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$application = [System.Windows.Application]::new()
$window = [System.Windows.Window]::new()
$window.Title = $Title
$window.Left = 1100; $window.Top = 500; $window.Width = 240; $window.Height = 120
$window.Topmost = $true
$surface = [System.Windows.Controls.Border]::new()
$surface.Background = [System.Windows.Media.Brushes]::LightGray
$label = [System.Windows.Controls.TextBlock]::new()
$label.Text = $Title
$surface.Child = $label
$window.Content = $surface
$window.AllowDrop = $true
$window.add_ContentRendered({ [IO.File]::WriteAllText($ResultPath + '.ready', 'ready') })
if ($Mode -in @('source', 'right-source', 'text')) {
    $window.add_PreviewMouseMove({
        $button = if ($Mode -eq 'right-source') { [System.Windows.Input.Mouse]::RightButton } else { [System.Windows.Input.Mouse]::LeftButton }
        if ($button -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        [IO.File]::WriteAllText($ResultPath + '.started', 'started')
        $data = [System.Windows.DataObject]::new()
        if ($Mode -ne 'text') { $data.SetData([System.Windows.DataFormats]::FileDrop, [string[]] @($Path)) }
        else { $data.SetData([System.Windows.DataFormats]::UnicodeText, 'not a file') }
        $effect = [System.Windows.DragDrop]::DoDragDrop($window, $data, [System.Windows.DragDropEffects]::Copy)
        [IO.File]::WriteAllText($ResultPath, $effect.ToString())
        $window.Close()
    })
} else {
    $window.add_PreviewDragOver({
        if ($_.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $_.Effects = [System.Windows.DragDropEffects]::Copy }
        else { $_.Effects = [System.Windows.DragDropEffects]::None }
        $_.Handled = $true
    })
    $window.add_PreviewDrop({
        $paths = [string[]] $_.Data.GetData([System.Windows.DataFormats]::FileDrop)
        foreach ($source in $paths) { [IO.File]::Copy($source, (Join-Path $Path ([IO.Path]::GetFileName($source)))) }
        $_.Effects = [System.Windows.DragDropEffects]::Copy
        $_.Handled = $true
        [IO.File]::WriteAllText($ResultPath, 'Copy')
        $window.Close()
    })
}
$null = $application.Run($window)