$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public sealed class SutShellTestSignal
{
    public readonly System.Threading.ManualResetEvent Event = new(false);
    public void Notify() => Event.Set();
}

public sealed class SutShellPriorityProbe
{
    public object First;
    public object Visible;
    public string Order = "";
    public void OnPropertyChanged(object sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName != "Entry" || sender.GetType().GetProperty("Entry").GetValue(sender) == null) return;
        if (object.ReferenceEquals(sender, Visible)) Order += "V";
        if (object.ReferenceEquals(sender, First)) Order += "B";
    }
}

public sealed class SutShellRenameProbe
{
    public string OldPath;
    public string NewPath;
    public void OnFolderRenamed(string oldPath, string newPath) { OldPath = oldPath; NewPath = newPath; }
}

public sealed class SutShellMenuProbe : System.IDisposable
{
    private delegate bool EnumWindowProc(System.IntPtr window, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindowProc callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(System.IntPtr window, System.Text.StringBuilder name, int maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SendMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool PostMessage(System.IntPtr window, uint message, System.IntPtr wparam, System.IntPtr lparam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int GetMenuItemCount(System.IntPtr menu);
    private readonly uint thread = GetCurrentThreadId();
    private readonly System.IntPtr owner;
    private readonly System.Threading.Timer timer;
    private int ticks;
    public int ItemCount = -1;

    public SutShellMenuProbe(System.IntPtr owner)
    {
        this.owner = owner;
        timer = new System.Threading.Timer(Check, null, 50, 50);
    }

    private void Check(object state)
    {
        EnumThreadWindows(thread, (window, parameter) =>
        {
            var name = new System.Text.StringBuilder(64);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() != "#32768") return true;
            var menu = SendMessage(window, 0x01E1, System.IntPtr.Zero, System.IntPtr.Zero);
            ItemCount = GetMenuItemCount(menu);
            PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
            return false;
        }, System.IntPtr.Zero);
        if (System.Threading.Interlocked.Increment(ref ticks) > 100)
            PostMessage(owner, 0x001F, System.IntPtr.Zero, System.IntPtr.Zero);
    }

    public void Dispose() => timer.Dispose();
}

public sealed class SutShellUiProbe
{
    public object List;
    public object Window;
    public bool Startup;
    public bool AwaitAll;
    public object Frame;
    public bool Ready;
    public string Error;
    private string state = "no rows";
    private int phase;
    private readonly System.DateTime deadline = System.DateTime.UtcNow.AddSeconds(20);

    private static object Property(object target, string name) => target.GetType().GetProperty(name).GetValue(target);

    private static bool ContainsImage(object visual, object source)
    {
        var image = visual.GetType().GetProperty("Source");
        if (image != null && object.ReferenceEquals(image.GetValue(visual), source)) return true;
        var helper = System.Type.GetType("System.Windows.Media.VisualTreeHelper, PresentationCore", true);
        var count = (int)helper.GetMethod("GetChildrenCount").Invoke(null, new[] { visual });
        for (var index = 0; index < count; index++)
            if (ContainsImage(helper.GetMethod("GetChild").Invoke(null, new[] { visual, (object)index }), source)) return true;
        return false;
    }

    private static object FindContentView(object visual)
    {
        if (visual.GetType().FullName == "SUTWinExplorer.ContentView") return visual;
        var helper = System.Type.GetType("System.Windows.Media.VisualTreeHelper, PresentationCore", true);
        var count = (int)helper.GetMethod("GetChildrenCount").Invoke(null, new[] { visual });
        for (var index = 0; index < count; index++)
        {
            var result = FindContentView(helper.GetMethod("GetChild").Invoke(null, new[] { visual, (object)index }));
            if (result != null) return result;
        }
        return null;
    }

    public void Tick(object sender, System.EventArgs args)
    {
        try
        {
            if (List == null && Window != null)
            {
                var content = FindContentView(Window);
                if (content != null) List = content.GetType().GetMethod("FindName").Invoke(content, new object[] { "FileList" });
            }
            if (List == null)
            {
                if (System.DateTime.UtcNow < deadline) return;
                Error = "Timed out waiting for BROWSE ContentView.";
                Frame.GetType().GetProperty("Continue").SetValue(Frame, false);
                return;
            }
            var items = Property(List, "Items");
            var count = (int)Property(items, "Count");
            if (AwaitAll && count > 0)
            {
                var loaded = 0;
                for (var index = 0; index < count; index++)
                {
                    var item = items.GetType().GetProperty("Item", new[] { typeof(int) }).GetValue(items, new object[] { index });
                    if (Property(item, "Entry") != null) loaded++;
                }
                state = "loaded=" + loaded + "/" + count;
                if (loaded == count) Ready = true;
                if (!Ready && System.DateTime.UtcNow < deadline) return;
                if (!Ready) Error = "Timed out waiting for background packages: " + state;
                Frame.GetType().GetProperty("Continue").SetValue(Frame, false);
                return;
            }
            if (count > 0)
            {
                var index = phase == 0 ? 0 : count - 1;
                var row = items.GetType().GetProperty("Item", new[] { typeof(int) }).GetValue(items, new object[] { index });
                var entry = Property(row, "Entry");
                var failed = row.GetType().GetProperty("Failed", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).GetValue(row);
                state = "count=" + count + ", entry=" + (entry != null) + ", failed=" + failed;
                if (entry != null && Property(entry, "Icons") is object icons)
                {
                    var generator = Property(List, "ItemContainerGenerator");
                    var container = generator.GetType().GetMethod("ContainerFromIndex").Invoke(generator, new object[] { index });
                    state += ", icons=true, container=" + (container != null);
                    if (container != null && ContainsImage(container, Property(icons, "BaseIcon")))
                    {
                        if (Startup) Ready = true;
                        else if (phase == 0)
                        {
                            var last = items.GetType().GetProperty("Item", new[] { typeof(int) }).GetValue(items, new object[] { count - 1 });
                            phase = 1;
                            List.GetType().GetMethod("ScrollIntoView", new[] { typeof(object) }).Invoke(List, new[] { last });
                        }
                        else Ready = true;
                    }
                }
            }
            if (!Ready && System.DateTime.UtcNow < deadline) return;
            if (!Ready) Error = "Timed out waiting for the visible row and rendered icon in phase " + phase + ": " + state;
        }
        catch (System.Exception exception)
        {
            Error = exception.ToString();
        }
        Frame.GetType().GetProperty("Continue").SetValue(Frame, false);
    }
}

public static class SutShellTestTypeName
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct ShellFileInfo
    {
        public System.IntPtr Icon;
        public int IconIndex;
        public uint Attributes;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 260)] public string DisplayName;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 80)] public string TypeName;
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern System.IntPtr SHGetFileInfo(string path, uint attributes, ref ShellFileInfo info, uint size, uint flags);

    public static string Get(string path)
    {
        var info = new ShellFileInfo();
        if (SHGetFileInfo(path, 0, ref info, (uint)System.Runtime.InteropServices.Marshal.SizeOf<ShellFileInfo>(), 0x400) == System.IntPtr.Zero)
            throw new System.InvalidOperationException("Shell type lookup failed.");
        return info.TypeName;
    }
}
'@

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Find-VisualName($parent, [string] $name) {
    for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
        if ($child -is [System.Windows.FrameworkElement] -and $child.Name -eq $name) { return $child }
        $match = Find-VisualName $child $name
        if ($null -ne $match) { return $match }
    }
    return $null
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($assemblyPath))
[System.Windows.Application].GetField('_resourceAssembly', [System.Reflection.BindingFlags]'Static,NonPublic').SetValue($null, $assembly)
$application = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.App', $true))
$application.InitializeComponent()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$shell = $assembly.GetType('SUTWinExplorer.SutShell', $true)
$flags = [System.Reflection.BindingFlags]'Static,NonPublic'
$openDirectory = $shell.GetMethod('OpenDirectoryAsync', $flags)
$getRange = $shell.GetMethod('GetDirectoryRangeAsync', $flags)
$ensureAccessible = $shell.GetMethod('EnsureDirectoryAccessible', $flags)
$observe = $shell.GetMethod('ObserveDirectories', $flags)
$rename = $shell.GetMethod('Rename', $flags)
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ('kis-shell-test-' + [guid]::NewGuid().ToString('N'))

try {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $directory 'Folder')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $directory 'notes.txt'), 'hello')
    [System.IO.File]::SetLastWriteTime((Join-Path $directory 'notes.txt'), [datetime]::new(2026, 11, 2, 9, 5, 0))
    [System.IO.File]::WriteAllText((Join-Path $directory '.internal'), 'hidden')
    [System.IO.File]::WriteAllText((Join-Path $directory 'unknown.zzzunknown'), 'unknown')
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'empty.bin'), [byte[]]::new(0))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'exact.bin'), [byte[]]::new(1024))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'over.bin'), [byte[]]::new(1025))
    [System.IO.File]::WriteAllBytes((Join-Path $directory 'large.bin'), [byte[]]::new(1048576))
    foreach ($badName in @('', '..', 'invalid/name', 'exact.bin')) {
        $failed = $false
        try { $null = $rename.Invoke($null, [object[]] @([string] (Join-Path $directory 'notes.txt'), [string] $badName, [IntPtr]::Zero)) } catch {
            $expectedType = if ($badName -eq 'exact.bin') { [System.IO.IOException] } else { [System.ArgumentException] }
            $failed = $expectedType.IsInstanceOfType($_.Exception.InnerException)
        }
        Assert-True $failed "Invalid or conflicting rename was accepted: $badName"
    }
    $casePath = Join-Path $directory 'case-only.tmp'
    [System.IO.File]::WriteAllText($casePath, 'case')
    $caseResult = $rename.Invoke($null, [object[]] @([string] $casePath, [string] 'CASE-only.tmp', [IntPtr]::Zero))
    $caseNames = @([System.IO.Directory]::EnumerateFileSystemEntries($directory) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    Assert-True ($caseResult -ceq (Join-Path $directory 'CASE-only.tmp') -and $caseNames -ccontains 'CASE-only.tmp') 'Case-only rename failed.'
    [System.IO.File]::Delete($caseResult)

    $snapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    Assert-True ($snapshot.Count -eq 8) 'Snapshot count is incorrect.'
    $all = @($getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($all.Count -eq 8 -and $all[0].IsDirectory) 'Enumeration or directory-first ordering failed.'
    $notes = $all | Where-Object { $_.FullPath -eq (Join-Path $directory 'notes.txt') }
    Assert-True ($null -ne $notes.Icons -and $notes.MediaTypeName -eq 'lines-text' -and $null -ne $notes.MediaTypeIcon) 'Shell icon or media type is missing.'
    $previousCulture = [System.Globalization.CultureInfo]::CurrentCulture
    try {
        foreach ($cultureName in @('de-DE', 'en-US', 'th-TH')) {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureName)
            Assert-True ($notes.ModifiedText -ceq '2026-11-02 09:05') "Date format changed under $cultureName."
        }
    } finally {
        [System.Globalization.CultureInfo]::CurrentCulture = $previousCulture
    }
    $unknown = $all | Where-Object { $_.FullPath -eq (Join-Path $directory 'unknown.zzzunknown') }
    Assert-True ($unknown.MediaTypeName -eq '' -and $null -eq $unknown.MediaTypeIcon) 'Unknown media type must be empty.'
    foreach ($entry in @($notes, $unknown, $all[0])) {
        Assert-True ($entry.Type -ceq [SutShellTestTypeName]::Get($entry.FullPath)) "Shell type mismatch for $($entry.FullPath)."
    }
    foreach ($case in @(@('empty.bin', 0), @('notes.txt', 1), @('exact.bin', 1), @('over.bin', 2), @('large.bin', 1024))) {
        $entry = $all | Where-Object { $_.FullPath -eq (Join-Path $directory $case[0]) }
        $expected = '{0:N0} KB' -f $case[1]
        Assert-True ($entry.SizeText -ceq $expected) "Size mismatch for $($case[0]): $($entry.SizeText)."
    }
    Assert-True ($all[0].SizeText -eq '') 'Directory size must be empty.'

    $page = @($getRange.Invoke($null, [object[]] @($snapshot, [int] 2, [int] 3, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($page.Count -eq 3 -and $page[0].FullPath -eq $all[2].FullPath -and $page[2].FullPath -eq $all[4].FullPath) 'Requested range does not match the snapshot order.'
    Assert-True ($notes.Icons.BaseIcon.IsFrozen -and $notes.MediaTypeIcon.IsFrozen) 'Complete row images must be frozen for the UI thread.'
    $parallelRanges = @(1..12 | ForEach-Object {
        $getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] $snapshot.Count, [Threading.CancellationToken]::None))
    })
    foreach ($task in $parallelRanges) {
        $parallelEntries = @($task.GetAwaiter().GetResult())
        Assert-True ($parallelEntries.Count -eq $snapshot.Count -and $null -ne $parallelEntries[0].Icons.BaseIcon) 'Concurrent range loading lost a Shell icon.'
    }
    $emptyPage = @($getRange.Invoke($null, [object[]] @($snapshot, [int] $snapshot.Count, [int] 0, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($emptyPage.Count -eq 0) 'Empty range must return no items.'
    $invalidRange = $false
    try { $null = $getRange.Invoke($null, [object[]] @($snapshot, [int] $snapshot.Count, [int] 1, [Threading.CancellationToken]::None)) } catch { $invalidRange = $true }
    Assert-True $invalidRange 'An out-of-bounds range was accepted.'
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-a.txt'), 'gone')
    [System.IO.File]::WriteAllText((Join-Path $directory 'vanish-b.txt'), 'present')
    $changingSnapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] 'vanish-*.txt', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    [System.IO.File]::Delete((Join-Path $directory 'vanish-a.txt'))
    $changedPage = @($getRange.Invoke($null, [object[]] @($changingSnapshot, [int] 0, [int] 2, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($changingSnapshot.Count -eq 2 -and $changedPage.Count -eq 2 -and $changedPage[1].FullPath -eq (Join-Path $directory 'vanish-b.txt') -and $null -ne $changedPage[1].Icons) 'A vanished item changed the snapshot range or blocked its neighbor.'
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $cancellation.Cancel()
        $cancelledTask = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $true, [bool] $false, [string] '', $cancellation.Token))
        $cancelled = $false
        try { $null = $cancelledTask.GetAwaiter().GetResult() } catch { $cancelled = $true }
        Assert-True ($cancelled -and $cancelledTask.IsCanceled) 'Cancelled enumeration completed instead of cancelling.'
        $cancelledRange = $getRange.Invoke($null, [object[]] @($snapshot, [int] 0, [int] 1, $cancellation.Token))
        $cancelled = $false
        try { $null = $cancelledRange.GetAwaiter().GetResult() } catch { $cancelled = $true }
        Assert-True ($cancelled -and $cancelledRange.IsCanceled) 'Cancelled range lookup completed instead of cancelling.'
    } finally {
        $cancellation.Dispose()
    }

    $filteredSnapshot = $openDirectory.Invoke($null, [object[]] @([string] $directory, [bool] $false, [bool] $true, [string] 'notes*.TXT', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    $filtered = @($getRange.Invoke($null, [object[]] @($filteredSnapshot, [int] 0, [int] $filteredSnapshot.Count, [Threading.CancellationToken]::None)).GetAwaiter().GetResult())
    Assert-True ($filtered.Count -eq 1 -and $filtered[0].FullPath -eq $notes.FullPath) 'Directory, internal, or case-insensitive pattern filtering failed.'
    $top = $openDirectory.Invoke($null, [object[]] @([string] '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}', [bool] $false, [bool] $true, [string] '', [Threading.CancellationToken]::None)).GetAwaiter().GetResult()
    Assert-True ($top.Count -eq 0) 'This PC must respect Hide directories.'

    $failed = $false
    try { $ensureAccessible.Invoke($null, @((Join-Path $directory 'missing'))) } catch { $failed = $true }
    Assert-True $failed 'A missing directory was accepted.'

    $signal = [SutShellTestSignal]::new()
    $callback = [Delegate]::CreateDelegate([Action], $signal, 'Notify')
    $observer = $observe.Invoke($null, @([string[]] @($directory), $callback))
    try {
        [System.IO.File]::WriteAllText((Join-Path $directory 'created.txt'), 'new')
        Assert-True ($signal.Event.WaitOne(5000)) 'External changes were not observed.'
    } finally {
        $observer.Dispose()
        $signal.Event.Dispose()
    }
    foreach ($index in 1..80) {
        [System.IO.File]::WriteAllText((Join-Path $directory ('visible-test-{0:D3}.txt' -f $index)), 'test')
    }
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $view = [Activator]::CreateInstance($assembly.GetType('SUTWinExplorer.ContentView', $true))
    $viewFlags = [System.Reflection.BindingFlags]'Instance,NonPublic'
    $null = $view.GetType().GetMethod('Initialize', $viewFlags).Invoke($view, [object[]] @([bool] $true))
    $window = [System.Windows.Window]::new()
    $window.ShowInTaskbar = $false
    $window.Left = -20000
    $window.Top = -20000
    $window.Width = 800
    $window.Height = 500
    $window.Content = $view
    $window.Show()
    try {
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $view.FindName('FileList')
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "ContentView did not load and render requested row packages: $($probe.Error)"
        $list = $view.FindName('FileList')
        $columns = $list.View.Columns
        Assert-True ($columns.Count -eq 7 -and $columns[3].Header -eq 'Name' -and
            $columns[3].Width -gt 80 -and $columns[4].Width -eq 130) 'Shell column order or name-column sizing is incorrect.'
        $iconSetType = $assembly.GetType('SUTWinExplorer.ShellIconSet', $true)
        $iconSet = $iconSetType.GetConstructor([type[]] @([System.Windows.Media.ImageSource], [System.Windows.Media.ImageSource], [double])).Invoke(
            [object[]] @($notes.Icons.BaseIcon, $notes.MediaTypeIcon, [double] 0.55))
        $entryType = $assembly.GetType('SUTWinExplorer.FileEntry', $true)
        $testEntry = $entryType.GetConstructors()[0].Invoke([object[]] @(
            $notes.Name, $notes.FullPath, $notes.IsDirectory, $notes.Type, $notes.SizeText,
            $notes.Modified, $iconSet, $notes.MediaTypeIcon, $notes.MediaTypeName))
        $rowType = $assembly.GetType('SUTWinExplorer.DirectoryRow', $true)
        $testRow = [Activator]::CreateInstance($rowType, $true)
        $rowType.GetProperty('Entry').SetValue($testRow, $testEntry)
        $cells = foreach ($column in @($columns[1], $columns[2])) {
            $presenter = [System.Windows.Controls.ContentPresenter]::new()
            $presenter.Content = $testRow
            $presenter.ContentTemplate = $column.CellTemplate
            $presenter.Measure([System.Windows.Size]::new(16, 16))
            $presenter.Arrange([System.Windows.Rect]::new(0, 0, 16, 16))
            $presenter.UpdateLayout()
            [System.Windows.Media.VisualTreeHelper]::GetChild($presenter, 0)
        }
        $baseCell = $cells[0]
        $overlayCell = $cells[1]
        Assert-True ([object]::ReferenceEquals($baseCell.Source, $notes.Icons.BaseIcon) -and
            [object]::ReferenceEquals($overlayCell.Source, $notes.MediaTypeIcon) -and
            $baseCell.Opacity -eq 0.55 -and $overlayCell.Opacity -eq 0.55) "Shell column binding mismatch: base=$([object]::ReferenceEquals($baseCell.Source, $notes.Icons.BaseIcon)), overlay=$([object]::ReferenceEquals($overlayCell.Source, $notes.MediaTypeIcon)), opacity=$($baseCell.Opacity)/$($overlayCell.Opacity)."
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Background packages did not complete: $($probe.Error)"
        $list.SelectedItems.Add($list.Items[0]) | Out-Null
        $list.SelectedItems.Add($list.Items[$list.Items.Count - 1]) | Out-Null
        $selectedPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($list.SelectedItems.Count -eq 2 -and $view.FindName('CopyGetButton').IsEnabled -and
            -not $view.FindName('PathGetButton').IsEnabled -and -not $view.FindName('RenameButton').IsEnabled) 'Multiple selection or its toolbar state failed.'
        foreach ($operation in @('Copy', 'Move')) {
            $view.FindName("${operation}GetButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $workflowType = $assembly.GetType("SUTWinExplorer.${operation}WorkflowState", $true)
            $workflow = $workflowType.GetProperty('Shared').GetValue($null)
            $preparedPaths = @($workflow.PreparedPaths)
            Assert-True ($preparedPaths.Count -eq 2 -and @($selectedPaths | Where-Object { $_ -notin $preparedPaths }).Count -eq 0) "$operation did not stage all selected paths."
            $view.FindName("${operation}AbortButton").RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        $menuProbe = [SutShellMenuProbe]::new([System.Windows.Interop.WindowInteropHelper]::new($window).Handle)
        try {
            $showItems = $shell.GetMethod('ShowItemMenu', $flags)
            $null = $showItems.Invoke($null, [object[]] @([string[]] $selectedPaths,
                [System.Windows.Interop.WindowInteropHelper]::new($window).Handle, $null))
            Assert-True ($menuProbe.ItemCount -gt 0) 'The Shell did not display a populated multi-item context menu.'
        } finally { $menuProbe.Dispose() }
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        $restoredPaths = @($list.SelectedItems | ForEach-Object { $_.Entry.FullPath })
        Assert-True ($probe.Ready -and $restoredPaths.Count -eq 2 -and
            @($selectedPaths | Where-Object { $_ -notin $restoredPaths }).Count -eq 0) "Multiple selection was not restored after consecutive refreshes: $($probe.Error)"
        $list.SelectedItems.Clear()
        $firstRow = $list.Items[0]
        $lastRow = $list.Items[$list.Items.Count - 1]
        $list.ScrollIntoView($lastRow)
        $list.UpdateLayout()
        $priority = [SutShellPriorityProbe]::new()
        $priority.First = $firstRow
        $priority.Visible = $lastRow
        $priorityCallback = [Delegate]::CreateDelegate([System.ComponentModel.PropertyChangedEventHandler], $priority, 'OnPropertyChanged')
        $firstRow.add_PropertyChanged($priorityCallback)
        $lastRow.add_PropertyChanged($priorityCallback)
        try {
            $firstRow.GetType().GetProperty('Entry').SetValue($firstRow, $null)
            $lastRow.GetType().GetProperty('Entry').SetValue($lastRow, $null)
            $view.GetType().GetField('_nextBackgroundIndex', $viewFlags).SetValue($view, 0)
            $null = $view.GetType().GetMethod('LoadNextRange', $viewFlags).Invoke($view, @())
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $probe = [SutShellUiProbe]::new()
            $probe.List = $list
            $probe.AwaitAll = $true
            $probe.Frame = $frame
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(25)
            $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
            $timer.Start()
            try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
            Assert-True ($probe.Ready -and $priority.Order -ceq 'VB') "Visible row did not precede background work: $($priority.Order) $($probe.Error)"
        } finally {
            $firstRow.remove_PropertyChanged($priorityCallback)
            $lastRow.remove_PropertyChanged($priorityCallback)
        }
        $list.ScrollIntoView($firstRow)
        $list.UpdateLayout()
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Scrolling did not load and render the requested range: $($probe.Error)"
        $list.SelectedItem = $list.Items[0]
        Assert-True $view.FindName('PathGetButton').IsEnabled 'Selecting a loaded row must enable Path get.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready "Rows were not ready for rename testing: $($probe.Error)"
        $notesRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'notes.txt') })[0]
        $list.SelectedItem = $notesRow
        Assert-True $view.FindName('RenameButton').IsEnabled 'Rename must be enabled for one loaded item.'
        $list.ScrollIntoView($notesRow)
        $list.UpdateLayout()
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::F2)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $list.RaiseEvent($keyEvent)
        $list.UpdateLayout()
        $editor = Find-VisualName $list.ItemContainerGenerator.ContainerFromItem($notesRow) 'ItemNameEditor'
        Assert-True ($null -ne $editor -and $editor.IsVisible -and $editor.Text -eq 'notes.txt') 'The inline rename editor was not rendered.'
        Assert-True ($notesRow.IsEditing -and $notesRow.EditName -eq 'notes.txt') 'Inline rename did not start with the actual file name.'
        $editor.Text = 'cancelled.txt'
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        Assert-True ([object]::ReferenceEquals($list.ItemsSource[0], $list.Items[0]) -and $notesRow.IsEditing) 'Refresh interrupted an active rename.'
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Escape)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $editor.RaiseEvent($keyEvent)
        Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'notes.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $directory 'cancelled.txt'))) 'Cancel changed the file.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and $list.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'notes.txt')) 'Deferred refresh did not retain the selected file.'
        $view.FindName('RenameButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $list.UpdateLayout()
        $editor = Find-VisualName $list.ItemContainerGenerator.ContainerFromItem($list.SelectedItem) 'ItemNameEditor'
        Assert-True ($null -ne $editor -and $editor.IsVisible) 'The inline editor did not reopen.'
        $editor.Text = 'renamed-notes.txt'
        $keyEvent = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($window), 0, [System.Windows.Input.Key]::Enter)
        $keyEvent.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
        $editor.RaiseEvent($keyEvent)
        Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'renamed-notes.txt')) -and
            -not (Test-Path -LiteralPath (Join-Path $directory 'notes.txt'))) 'Inline rename did not rename the file correctly.'
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and $list.SelectedItem.Entry.FullPath -eq (Join-Path $directory 'renamed-notes.txt')) 'Renamed file was not reselected.'
        $view.FindName('HideDirectoriesCheckBox').GetCheckBox().IsChecked = $false
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.AwaitAll = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True $probe.Ready 'Directory rows were not loaded for rename testing.'
        $folderRow = @($list.Items | Where-Object { $_.Entry.FullPath -eq (Join-Path $directory 'Folder') })[0]
        $list.SelectedItem = $folderRow
        $renameProbe = [SutShellRenameProbe]::new()
        $folderEvent = $view.GetType().GetEvent('FolderRenamed', $viewFlags)
        $folderCallback = [Delegate]::CreateDelegate([Action[string,string]], $renameProbe, 'OnFolderRenamed')
        $folderEvent.GetAddMethod($true).Invoke($view, [object[]] @($folderCallback))
        try {
            $null = $view.GetType().GetMethod('BeginRename', $viewFlags).Invoke($view, @())
            $folderRow.EditName = 'RenamedFolder'
            $null = $view.GetType().GetMethod('EndRename', $viewFlags).Invoke($view, [object[]] @([bool] $true))
            Assert-True ((Test-Path -LiteralPath (Join-Path $directory 'RenamedFolder')) -and
                $renameProbe.OldPath -eq (Join-Path $directory 'Folder') -and
                $renameProbe.NewPath -eq (Join-Path $directory 'RenamedFolder')) 'Directory rename was not propagated.'
        } finally {
            $folderEvent.GetRemoveMethod($true).Invoke($view, [object[]] @($folderCallback))
        }
        $otherDirectory = Join-Path $directory 'navigation-test'
        [System.IO.Directory]::CreateDirectory($otherDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $otherDirectory 'other.txt'), 'other')
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $otherDirectory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $null = $view.GetType().GetMethod('SetCurrentPath', $viewFlags).Invoke($view, [object[]] @([string] $directory))
        $null = $view.GetType().GetMethod('Refresh', $viewFlags).Invoke($view, [object[]] @([bool] $true))
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $probe = [SutShellUiProbe]::new()
        $probe.List = $list
        $probe.Startup = $true
        $probe.Frame = $frame
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(25)
        $timer.add_Tick([Delegate]::CreateDelegate([EventHandler], $probe, 'Tick'))
        $timer.Start()
        try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
        Assert-True ($probe.Ready -and [System.IO.Path]::GetDirectoryName($list.Items[0].Entry.FullPath) -eq $directory) "A stale navigation replaced the current snapshot: $($probe.Error)"
    } finally {
        $window.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    $previousContext = [System.Threading.SynchronizationContext]::Current
    [System.Threading.SynchronizationContext]::SetSynchronizationContext(
        [System.Windows.Threading.DispatcherSynchronizationContext]::new([System.Windows.Threading.Dispatcher]::CurrentDispatcher))
    $profileDirectory = Join-Path $directory 'profiles'
    $storeType = $assembly.GetType('SUTWinExplorer.ProfileStore', $true)
    $store = $storeType.GetConstructor([type[]] @([string], [string])).Invoke([object[]] @([string] $profileDirectory, [string] 'default'))
    $profile = $store.LoadOrCreate()
    $application.GetType().GetMethod('SetActiveProfile', $viewFlags).Invoke($application, [object[]] @($store, $profile))
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
        Assert-True $probe.Ready "BROWSE startup did not render a Shell icon: $($probe.Error)"
    } finally {
        $mainWindow.Close()
        [System.Threading.SynchronizationContext]::SetSynchronizationContext($previousContext)
    }
    'SutShell tests passed.'
} finally {
    $application.Shutdown()
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}