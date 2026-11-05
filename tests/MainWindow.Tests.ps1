. (Join-Path $PSScriptRoot 'SutShell.TestHelpers.ps1')

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
$testView = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
$menuActionOrder = @($testView.GetType().GetMethod('CreateContextMenuActions', $viewFlags).Invoke($testView, @()) | ForEach-Object { $_.Id })
[SutShellRightClickProbe]::PropertiesCommandId = Get-ActionCommandId 'Properties'
[SutShellRightClickProbe]::NameClipboardCopyCommandId = Get-ActionCommandId 'NameClipboardCopy'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-mainwindow-test-' + [guid]::NewGuid().ToString('N'))
$originalCursor = [SutShellRightClickProbe]::CursorPosition()

try {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'renamed-notes.txt'), 'notes')
    [System.IO.File]::WriteAllText((Join-Path $directory 'other.txt'), 'other')
    Assert-True ((Get-ActionCommandId 'Properties') -eq 0x8000) 'The menu action order is unavailable.'
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $useCaseDirectory = Join-Path $directory 'use-cases'
    $storeType = $assembly.GetType('SUTWinExplorer.UseCaseStore', $true)
    $store = $storeType.GetConstructor([type[]] @([string], [string])).Invoke([object[]] @([string] $useCaseDirectory, [string] 'default'))
    $useCase = $store.LoadOrCreate()
    $application.GetType().GetMethod('SetActiveUseCase', $viewFlags).Invoke($application, [object[]] @($store, $useCase))
    $mainWindow = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.MainWindow', $true))
    $mainWindow.ShowInTaskbar = $false
    $mainWindow.Left = -20000
    $mainWindow.Top = -20000
    $mainWindow.Show()
    try {
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.Window = $mainWindow
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $browseStatus = if ($null -ne $probe.ContentView) { $probe.ContentView.FindName('StatusLabel').Text } else { 'no ContentView' }
        Assert-True $probe.Ready "BROWSE startup did not render a Shell icon: $($probe.Error); status=$browseStatus"
        $addressBox = $mainWindow.FindName('AddressBox')
        $addressCopy = $mainWindow.FindName('AddressClipboardCopyButton')
        $addressPaste = $mainWindow.FindName('AddressClipboardPasteButton')
        Assert-True ($addressCopy.IsEnabled -and $addressCopy.Content.Template -eq $mainWindow.FindResource('ClipboardCopyIconTemplate')) 'The address copy button is disabled or has the wrong icon.'
        Assert-True ($addressPaste.IsEnabled -and $addressPaste.Content.Template -eq $mainWindow.FindResource('ClipboardPasteIconTemplate')) 'The address paste button is disabled or has the wrong icon.'
        $originalClipboard = [System.Windows.Clipboard]::GetDataObject()
        try {
            $addressBox.Text = 'C:\unconfirmed address'
            $addressCopy.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ([System.Windows.Clipboard]::GetText() -ceq $addressBox.Text) 'Address copy did not copy the current editor text.'
            $addressBox.Text = ''
            $addressCopy.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ([System.Windows.Clipboard]::GetText() -ceq 'C:\unconfirmed address') 'An empty address changed the clipboard.'
            [System.Windows.Clipboard]::SetText([string] $directory)
            $addressPaste.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ([string]::Equals($mainWindow.FindName('ExplorerTabs').SelectedItem.Content.CurrentPath, $directory, [StringComparison]::OrdinalIgnoreCase)) 'Address paste did not navigate to the clipboard path.'
            $pastedAddress = $addressBox.Text
            [System.Windows.Clipboard]::SetText('   ')
            $addressPaste.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ($addressBox.Text -ceq $pastedAddress) 'Whitespace clipboard text changed the address.'
            [System.Windows.Clipboard]::SetDataObject([System.Windows.DataObject]::new('SutNonTextProbe', 'value'), $true)
            $addressPaste.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Assert-True ($addressBox.Text -ceq $pastedAddress) 'Non-text clipboard content changed the address.'
        } finally {
            if ($null -eq $originalClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($originalClipboard, $true) }
        }
        $mainView = $probe.ContentView
        $null = $mainView.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($mainView, [object[]] @([string] $directory))
        $null = $mainView.GetType().GetMethod('Refresh', $viewFlags).Invoke($mainView, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $mainView.FindName('FileList')
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "MainWindow content did not load: $($probe.Error)"
        $mainList = $mainView.FindName('FileList')
        $mainNotes = @($mainList.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt') })[0]
        $mainOther = $mainList.Items[($mainList.Items.IndexOf($mainNotes) + 1) % $mainList.Items.Count]
        $mainWindow.Width = 1000
        $mainWindow.Height = 700
        $mainWindow.Left = 20
        $mainWindow.Top = 20
        $mainWindow.Activate() | Out-Null
        $mainWindow.UpdateLayout()
        $mainList.ScrollIntoView($mainOther)
        $mainList.UpdateLayout()
        $notesContainer = $mainList.ItemContainerGenerator.ContainerFromItem($mainNotes)
        $otherContainer = $mainList.ItemContainerGenerator.ContainerFromItem($mainOther)
        Assert-True ($null -ne $notesContainer -and $null -ne $otherContainer) "MainWindow test rows were not realized: notes=$($null -ne $mainNotes), other=$($null -ne $mainOther), notesContainer=$($null -ne $notesContainer), otherContainer=$($null -ne $otherContainer), visible=$($mainList.IsVisible), size=$($mainList.ActualWidth)x$($mainList.ActualHeight)."
        $startPoint = $notesContainer.PointToScreen([System.Windows.Point]::new(200, $notesContainer.ActualHeight / 2))
        $samePoint = $notesContainer.PointToScreen([System.Windows.Point]::new(10, $notesContainer.ActualHeight / 2))
        $otherPoint = $otherContainer.PointToScreen([System.Windows.Point]::new(10, $otherContainer.ActualHeight / 2))
        $mainOwner = [System.Windows.Interop.WindowInteropHelper]::new($mainWindow).Handle
        foreach ($target in @('double', 'same', 'other')) {
            $mainList.SelectedItems.Clear()
            $mainList.SelectedItem = $mainNotes
            $origin = if ($target -eq 'double') { $samePoint } else { $startPoint }
            $destination = if ($target -eq 'other') { $otherPoint } else { $samePoint }
            $hitSource = $mainList.InputHitTest($mainList.PointFromScreen($origin))
            $hitPath = [System.Collections.Generic.List[string]]::new()
            $hitAncestor = $hitSource
            while ($null -ne $hitAncestor) {
                $hitPath.Add($hitAncestor.GetType().Name)
                $hitAncestor = [System.Windows.Media.VisualTreeHelper]::GetParent($hitAncestor)
            }
            $rightClickProbe = [SutShellRightClickProbe]::new($mainOwner, [int] $origin.X, [int] $origin.Y, [int] $destination.X, [int] $destination.Y)
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(7)
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $timer.add_Tick({ if ($rightClickProbe.SecondMenu -or [DateTime]::UtcNow -ge $deadline) { $frame.Continue = $false } }.GetNewClosure())
            $timer.Start()
            try {
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                $expectedRow = if ($target -eq 'other') { $mainOther } else { $mainNotes }
                Assert-True ($rightClickProbe.FirstMenu -and $rightClickProbe.SecondMenu -and
                    $rightClickProbe.SecondWasBase -eq ($target -eq 'other') -and $mainList.SelectedItems.Count -eq 1 -and
                    $mainList.SelectedItem.Entry.FullPath -eq $expectedRow.Entry.FullPath) "MainWindow right-click failed for target=$target`: first=$($rightClickProbe.FirstMenu), firstLabel=$($rightClickProbe.ObservedFirstLabel), start=$($origin.X),$($origin.Y), actualStart=$($rightClickProbe.ActualStart -join ','), startClass=$($rightClickProbe.StartClass), hit=$($hitPath -join '/'), second=$($rightClickProbe.SecondMenu), base=$($rightClickProbe.SecondWasBase), targetClass=$($rightClickProbe.TargetClass), selection=$($mainList.SelectedItems.Count), selected=$($mainList.SelectedItem.Entry.FullPath)."
            } finally { $timer.Stop(); $rightClickProbe.Dispose() }
        }
    } finally {
        $mainWindow.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    'MainWindow tests passed.'
} finally {
    [SutShellRightClickProbe]::MovePointer($originalCursor[0], $originalCursor[1])
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}