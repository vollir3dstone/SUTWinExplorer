$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AssociationTestNative
{
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint thread, uint other, bool attach);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr window);
    public static bool ActivateTestWindow(IntPtr window)
    {
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        uint current = GetCurrentThreadId();
        bool attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
        try { BringWindowToTop(window); return SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
    }
}
'@

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Wait-PasteMessages([int] $expected) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $timer.add_Tick({
        if ($script:pasteMessages -ge $expected -or [DateTime]::UtcNow -ge $deadline) {
            $timer.Stop()
            $frame.Continue = $false
        }
    }.GetNewClosure())
    $timer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timer.Stop() }
}

$assemblyPath = Join-Path $PSScriptRoot '..\bin\Debug\net10.0-windows\SUTWinExplorer.dll'
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
$accessor = $assembly.GetType('SUTWinExplorer.RunningAppsAccessor', $true)
$appType = $assembly.GetType('SUTWinExplorer.RegisteredApp', $true)
$processPath = [string] (Get-Process -Id $PID).Path
$suffix = [guid]::NewGuid().ToString('N')
$extension = ".kistest$suffix"
$progId = "KisRunningAppsTest.$suffix"
$extensionKey = "Software\Classes\$extension"
$programKey = "Software\Classes\$progId"
$first = [System.Windows.Window]::new()
$second = [System.Windows.Window]::new()
$hidden = [System.Windows.Window]::new()
$dialog = [System.Windows.Window]::new()
$untitled = [System.Windows.Window]::new()

try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($extensionKey)
    try { $key.SetValue('', $progId) } finally { $key.Dispose() }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$programKey\shell\open\command")
    try { $key.SetValue('', ('"{0}" "%1"' -f $processPath)) } finally { $key.Dispose() }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($programKey)
    try { $key.SetValue('', 'KIS Running Apps Test') } finally { $key.Dispose() }
    [AssociationTestNative]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

    $first.Title = "KIS first $suffix"
    $second.Title = "KIS second $suffix"
    $hidden.Title = "KIS hidden $suffix"
    $dialog.Title = "KIS dialog $suffix"
    $untitled.Title = ''
    $first.Show()
    $second.Show()
    $dialog.Owner = $first
    $dialog.Show()
    $untitled.Show()
    $firstHandle = [System.Windows.Interop.WindowInteropHelper]::new($first).Handle
    $secondHandle = [System.Windows.Interop.WindowInteropHelper]::new($second).Handle
    $dialogHandle = [System.Windows.Interop.WindowInteropHelper]::new($dialog).Handle
    $untitledHandle = [System.Windows.Interop.WindowInteropHelper]::new($untitled).Handle

    $app = $appType.GetConstructor([type[]] @([string], [string])).Invoke([object[]] @($processPath, 'Test app'))
    $windows = @($accessor.GetMethod('GetUserWindows').Invoke($null, @($app)))
    Assert-True (@($windows | Where-Object { $_.Handle -eq $firstHandle -and $_.Title -eq $first.Title }).Count -eq 1) 'The first visible window was not found with its title.'
    Assert-True (@($windows | Where-Object { $_.Handle -eq $secondHandle -and $_.Title -eq $second.Title }).Count -eq 1) 'The second visible window was not found with its title.'
    Assert-True (@($windows | Where-Object { $_.Handle -eq $dialogHandle -and $_.Title -eq $dialog.Title }).Count -eq 1) 'The visible owned dialog was not found.'
    Assert-True (@($windows | Where-Object { $_.Handle -eq $untitledHandle -and $_.Title -eq '' }).Count -eq 1) 'The visible untitled window was not found.'
    Assert-True (@($windows | Where-Object Title -eq $hidden.Title).Count -eq 0) 'A hidden window was returned.'
    $otherApp = $appType.GetConstructor([type[]] @([string], [string])).Invoke([object[]] @('C:\nonexistent\unrelated.exe', 'Other app'))
    Assert-True (@($accessor.GetMethod('GetUserWindows').Invoke($null, @($otherApp))).Count -eq 0) 'Windows from an unrelated app were returned.'

    $filePath = "C:\example\document$extension"
    $apps = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @($filePath)))
    $registered = @($apps | Where-Object { $_.Id -ieq $processPath })
    Assert-True ($registered.Count -eq 1) "The registered application was not found: $($apps.Id -join ', ')."
    Assert-True (-not [string]::IsNullOrWhiteSpace($registered[0].Name)) 'The registered application has no display name.'
    $running = @($accessor.GetMethod('GetRunningApps').Invoke($null, @($filePath)))
    $match = @($running | Where-Object { $_.App.Id -ieq $processPath })
    Assert-True ($match.Count -eq 1) 'The registered running application was not found.'
    Assert-True (@($match[0].Windows | Where-Object Handle -eq $firstHandle).Count -eq 1) 'The combined result did not contain the visible window.'
    Assert-True (@($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @('C:\example\no-extension'))).Count -eq 0) 'An extensionless path returned registered applications.'

    $wavApps = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @('C:\example\audio.wav')))
    $wavExtensionApps = @($accessor.GetMethod('GetAppsToChooseFrom').Invoke($null, @('.WAV')))
    $wavIds = @($wavApps | ForEach-Object { $_.Id } | Sort-Object)
    $wavExtensionIds = @($wavExtensionApps | ForEach-Object { $_.Id } | Sort-Object)
    Assert-True ($wavIds.Count -eq $wavExtensionIds.Count -and @($wavIds | Where-Object { $_ -notin $wavExtensionIds }).Count -eq 0) 'The WAV path and extension returned different registered applications.'
    foreach ($wavApp in $wavApps) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($wavApp.Id) -and -not [string]::IsNullOrWhiteSpace($wavApp.Name)) 'A WAV application has no ID or name.'
    }
    $wavRunning = @($accessor.GetMethod('GetRunningApps').Invoke($null, @('C:\example\audio.wav')))
    foreach ($runningApp in $wavRunning) {
        Assert-True ($runningApp.App.Id -in $wavIds) 'A running WAV application was not registered for WAV files.'
        Assert-True ($runningApp.Windows.Count -gt 0) 'A running WAV application has no user windows.'
        foreach ($window in $runningApp.Windows) {
            Assert-True ($window.Handle -ne [IntPtr]::Zero) 'A WAV application window has no handle.'
        }
    }
    "WAV: $($wavApps.Count) registered applications, $($wavRunning.Count) with visible windows."

    $previousClipboard = [System.Windows.Clipboard]::GetDataObject()
    $clipboardRestoreError = $null
    $fileOne = [IO.Path]::GetTempFileName()
    $fileTwo = [IO.Path]::GetTempFileName()
    $script:pasteMessages = 0
    $script:transferEvents = [Collections.Generic.List[string]]::new()
    $textBox = [System.Windows.Controls.TextBox]::new()
    $first.Content = $textBox
    $keyHandler = [System.Windows.Input.KeyEventHandler] {
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::V -and
            ($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $script:pasteMessages++
            $script:transferEvents.Add('Paste')
            $eventArgs.Handled = $true
        }
    }
    $first.Add_PreviewKeyDown($keyHandler)
    try {
        $pasteMethod = $accessor.GetMethod('PasteByInteractionToAppWindow')
        $target = @($windows | Where-Object Handle -eq $firstHandle)[0].PSObject.BaseObject
        [System.Windows.Clipboard]::SetText('not a file list')
        $result = $pasteMethod.Invoke($null, @($target))
        Assert-True (-not $result.Sent -and $result.Error -and $script:pasteMessages -eq 0) 'Text in the clipboard was not rejected.'

        $fileList = [Collections.Specialized.StringCollection]::new()
        $null = $fileList.Add($fileOne)
        [System.Windows.Clipboard]::SetFileDropList($fileList)
        Assert-True ([AssociationTestNative]::ActivateTestWindow($firstHandle)) 'Could not activate the test window.'
        $null = $first.Activate()
        $null = $textBox.Focus()
        $null = $second.Activate()
        $result = $pasteMethod.Invoke($null, @($target))
        Assert-True ($result.Sent -and -not $result.Error) "A single clipboard file did not send Ctrl+V: $($result.Error)"
        Wait-PasteMessages 1
        Assert-True ($script:pasteMessages -eq 1) 'The target window did not receive Ctrl+V for a single file.'
        Assert-True ([AssociationTestNative]::GetForegroundWindow() -eq $firstHandle) 'The target window was not activated.'

        $null = $fileList.Add($fileTwo)
        [System.Windows.Clipboard]::SetFileDropList($fileList)
        $result = $pasteMethod.Invoke($null, @($target))
        Assert-True ($result.Sent) "A clipboard file list did not send Ctrl+V: $($result.Error)"
        Wait-PasteMessages 2
        Assert-True ($script:pasteMessages -eq 2) 'The target window did not receive Ctrl+V for a file list.'

        $invalid = $assembly.GetType('SUTWinExplorer.AppWindow', $true).GetConstructor([type[]] @([IntPtr], [string])).Invoke([object[]] @([IntPtr]::Zero, 'invalid'))
        $result = $pasteMethod.Invoke($null, @($invalid))
        Assert-True (-not $result.Sent -and $result.Error -and $script:pasteMessages -eq 2) 'An invalid window was not rejected.'
        $folderList = [Collections.Specialized.StringCollection]::new()
        $null = $folderList.Add([IO.Path]::GetTempPath())
        [System.Windows.Clipboard]::SetFileDropList($folderList)
        $result = $pasteMethod.Invoke($null, @($target))
        Assert-True (-not $result.Sent -and $result.Error -and $script:pasteMessages -eq 2) 'A clipboard folder was not rejected.'

        $dropMethod = $accessor.GetMethod('DropToAppWindow')
        $dropAtMethod = $accessor.GetMethod('DropToAppWindowAt')
        $result = $dropMethod.Invoke($null, [object[]] @($target, [string[]] @()))
        Assert-True (-not $result.Dropped -and $result.Error) 'An empty drag was not rejected.'
        $dialog.Hide()
        $first.Left = 100; $first.Top = 100; $first.Width = 500; $first.Height = 400
        $result = $dropAtMethod.Invoke($null, [object[]] @($target, [string[]] @($fileOne), -1, 10))
        Assert-True (-not $result.Dropped -and $result.Error) 'A drop point outside the client area was not rejected.'
        $dropSurface = [System.Windows.Controls.Border]::new()
        $dropSurface.Background = [System.Windows.Media.Brushes]::LightGray
        $dropSurface.AllowDrop = $true
        $dropSurface.Focusable = $true
        $first.Content = $dropSurface
        $script:droppedFiles = @()
        $script:dragEvents = 0
        $dragHandler = [System.Windows.DragEventHandler] {
            param($sender, $eventArgs)
            $script:dragEvents++
            if ($eventArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
                $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
            } else { $eventArgs.Effects = [System.Windows.DragDropEffects]::None }
            $eventArgs.Handled = $true
        }
        $dropHandler = [System.Windows.DragEventHandler] {
            param($sender, $eventArgs)
            $script:transferEvents.Add('Drop')
            $script:droppedFiles = @($eventArgs.Data.GetData([System.Windows.DataFormats]::FileDrop))
            $eventArgs.Effects = [System.Windows.DragDropEffects]::Copy
            $eventArgs.Handled = $true
        }
        $dropSurface.Add_DragEnter($dragHandler)
        $dropSurface.Add_DragOver($dragHandler)
        $dropSurface.Add_Drop($dropHandler)
        try {
            $result = $dropMethod.Invoke($null, [object[]] @($target, [string[]] @($fileOne, $fileTwo)))
            Assert-True ($result.Dropped -and -not $result.Error) "The OLE file drag failed: $($result.Error); drag events: $script:dragEvents."
            Assert-True ($script:droppedFiles.Count -eq 2 -and $fileOne -in $script:droppedFiles -and $fileTwo -in $script:droppedFiles) 'The drop target did not receive both files.'
            $script:droppedFiles = @()
            $result = $dropAtMethod.Invoke($null, [object[]] @($target, [string[]] @($fileOne), 100, 100))
            Assert-True ($result.Dropped -and @($script:droppedFiles | Where-Object { $_ -eq $fileOne }).Count -eq 1) "The explicit drop point failed: $($result.Error)"
            $otherDirectory = Join-Path ([IO.Path]::GetTempPath()) ('kis-drag-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($otherDirectory) | Out-Null
            try {
                $otherFile = [string] (Join-Path $otherDirectory 'other.txt')
                [IO.File]::WriteAllText($otherFile, 'other')
                $script:droppedFiles = @()
                $result = $dropMethod.Invoke($null, [object[]] @($target, [string[]] @($fileOne, $otherFile)))
                Assert-True ($result.Dropped -and -not $result.Error) "The cross-directory OLE drag failed: $($result.Error)"
                Assert-True ($script:droppedFiles.Count -eq 2 -and $fileOne -in $script:droppedFiles -and $otherFile -in $script:droppedFiles) 'The drop target did not receive files from different directories.'
            } finally { [IO.Directory]::Delete($otherDirectory, $true) }
        } finally {
            $dropSurface.Remove_DragEnter($dragHandler)
            $dropSurface.Remove_DragOver($dragHandler)
            $dropSurface.Remove_Drop($dropHandler)
        }
    } finally {
        $first.Remove_PreviewKeyDown($keyHandler)
        [IO.File]::Delete($fileOne)
        [IO.File]::Delete($fileTwo)
        try {
            if ($null -eq $previousClipboard) { [System.Windows.Clipboard]::Clear() }
            else { [System.Windows.Clipboard]::SetDataObject($previousClipboard, $true) }
        } catch { $clipboardRestoreError = $_; Write-Warning "Could not restore the clipboard: $_" }
    }
    if ($null -ne $clipboardRestoreError) { throw $clipboardRestoreError }
    'Running apps accessor tests passed.'
} finally {
    $dialog.Close()
    $untitled.Close()
    $first.Close()
    $second.Close()
    $hidden.Close()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($extensionKey, $false)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($programKey, $false)
    [AssociationTestNative]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}